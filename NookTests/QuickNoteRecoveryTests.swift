import Foundation
import Testing
@testable import Nook

@MainActor
private final class QuickNoteDiscardDecision {
    var allowsDiscard = false
    private(set) var requestCount = 0

    func request() -> Bool {
        requestCount += 1
        return allowsDiscard
    }
}

@MainActor
struct QuickNoteRecoveryTests {
    private func fixture() throws -> (URL, MarkdownStore, DraftJournal) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NookQuickRecovery-\(UUID().uuidString)")
        let library = directory.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let store = MarkdownStore(noteLoader: { _, _ in .success((notes: [], issues: [])) })
        store.storageURL = library
        let journal = DraftJournal(directoryURL: directory.appendingPathComponent("Drafts"))
        return (directory, store, journal)
    }

    @Test
    func unfinishedPadSurvivesRestartWithoutOpeningOrSavingANote() async throws {
        let (directory, store, journal) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pad = QuickNoteController(store: store, recovery: journal)
        pad.text = "  A thought with its own spacing.\n\n"
        await journal.flush()
        let restarted = DraftJournal(directoryURL: journal.directoryURL)
        await restarted.scan()
        let recovered = try #require(restarted.recoveredDrafts.first)
        #expect(recovered.kind == .quickNote)
        #expect(recovered.text == pad.text)
        #expect(recovered.libraryPath == store.storageURL.resolvingSymlinksInPath().path)
        #expect(recovered.baseline == "")
        #expect(store.notes.isEmpty)
        #expect(!pad.isPresenting)
    }

    @Test
    func unicodeNormalizationChangesStillCheckpointTheExactTypedBytes() async throws {
        let (directory, store, journal) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pad = QuickNoteController(store: store, recovery: journal)
        pad.text = "Caf\u{00E9}"
        await journal.flush()
        pad.text = "Cafe\u{0301}"
        await journal.flush()
        let restarted = DraftJournal(directoryURL: journal.directoryURL)
        await restarted.scan()
        let recovered = try #require(restarted.recoveredDrafts.first)
        #expect(Data(recovered.text.utf8) == Data("Cafe\u{0301}".utf8))
    }

    @Test
    func aSavedPadsEmptyReplacementStillHasARecoveryCopy() async throws {
        let (directory, store, journal) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pad = QuickNoteController(store: store, recovery: journal)
        pad.text = "Keep the original and an empty replacement distinct."
        let saved = try #require(pad.saveIfNeeded())
        pad.text = ""
        #expect(!pad.canClose())
        await journal.flush()
        let restarted = DraftJournal(directoryURL: journal.directoryURL)
        await restarted.scan()
        let recovered = try #require(restarted.recoveredDrafts.first)
        #expect(recovered.text == "")
        #expect(recovered.noteID == saved.id)
        #expect(recovered.baseline == MarkdownCodec.encode(saved))
        #expect(recovered.baselineRevision == saved.fileRevision)
        #expect(store.notes.first?.summary == saved.summary)
    }

    @Test
    func clearingEmptyValidationDoesNotClearAnIndependentRecoveryFailure() async throws {
        let (directory, store, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = DraftJournal(
            directoryURL: directory.appendingPathComponent("FailingDrafts"),
            beforeFileOperation: { operation, _ in
                if case .write = operation { throw CocoaError(.fileWriteOutOfSpace) }
            }
        )
        let pad = QuickNoteController(store: store, recovery: journal)
        pad.text = "Original synthetic thought."
        let saved = try #require(pad.saveIfNeeded())
        let file = try #require(saved.fileURL)
        let originalBytes = try Data(contentsOf: file)
        pad.text = ""
        #expect(pad.saveIfNeeded() == nil)
        await journal.flush()
        let recoveryFailure = try #require(pad.recoveryWarning)

        pad.text = "Restored synthetic thought."
        #expect(pad.message == nil)
        #expect(pad.recoveryWarning == recoveryFailure)
        #expect(!pad.hasUnsavedFailure)
        #expect(pad.hasUnsavedEdits)
        #expect(try Data(contentsOf: file) == originalBytes)
        await journal.flush()
        #expect(pad.recoveryWarning != nil)
    }

    @Test
    func switchingFoldersNeverRedirectsThePadsPendingWords() async throws {
        let (directory, store, journal) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pad = QuickNoteController(store: store, recovery: journal)
        let originalLibrary = store.storageURL
        pad.text = "This thought belongs to the first folder."
        pad.libraryWillChange()
        let other = directory.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        store.storageURL = other
        #expect(pad.saveIfNeeded() == nil)
        #expect(pad.hasUnsavedFailure)
        #expect(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
        await journal.flush()
        let restarted = DraftJournal(directoryURL: journal.directoryURL)
        await restarted.scan()
        #expect(restarted.recoveredDrafts.first?.libraryPath == originalLibrary.path)
    }

    @Test
    func externalDeletionKeepsTheDraftAndDoesNotRecreateTheFile() async throws {
        let (directory, store, journal) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pad = QuickNoteController(store: store, recovery: journal)
        pad.text = "The saved version."
        let saved = try #require(pad.saveIfNeeded())
        let url = try #require(saved.fileURL)
        try FileManager.default.removeItem(at: url)
        pad.text = "The unfinished version after deletion."
        #expect(pad.saveIfNeeded() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        await journal.flush()
        let restarted = DraftJournal(directoryURL: journal.directoryURL)
        await restarted.scan()
        #expect(restarted.recoveredDrafts.first?.text == pad.text)
    }

    @Test
    func aVerifiedSaveAndExplicitDeletionDoNotResurrectDrafts() async throws {
        let (directory, store, journal) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pad = QuickNoteController(store: store, recovery: journal)
        pad.text = "Ready to save."
        let saved = try #require(pad.saveIfNeeded())
        await journal.flush()
        let restarted = DraftJournal(directoryURL: journal.directoryURL)
        await restarted.scan()
        #expect(restarted.recoveredDrafts.isEmpty)
        pad.text = "An edit about to be explicitly discarded."
        pad.noteWasDeleted(saved)
        await journal.flush()
        await restarted.scan()
        #expect(restarted.recoveredDrafts.isEmpty)
        #expect(pad.text.isEmpty)
    }

    @Test
    func discardCannotTrashACopiedLibraryOrAnExternalEdit() async throws {
        let (directory, store, journal) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pad = QuickNoteController(store: store, recovery: journal)
        pad.text = "Saved in the first folder."
        let saved = try #require(pad.saveIfNeeded())
        let file = try #require(saved.fileURL)
        let originalBytes = try Data(contentsOf: file)
        let originalLibrary = store.storageURL
        let other = directory.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let copy = other.appendingPathComponent(file.lastPathComponent)
        try originalBytes.write(to: copy)
        pad.text = "An unsaved edit belonging to the first folder."
        pad.libraryWillChange()
        store.storageURL = other
        pad.discard()
        #expect(pad.hasUnsavedFailure)
        #expect(!pad.text.isEmpty)
        #expect(try Data(contentsOf: file) == originalBytes)
        #expect(try Data(contentsOf: copy) == originalBytes)
        store.storageURL = originalLibrary
        let externalBytes = originalBytes + Data("\nExternal words".utf8)
        try externalBytes.write(to: file)
        pad.discard()
        #expect(pad.hasUnsavedFailure)
        #expect(try Data(contentsOf: file) == externalBytes)
        await journal.flush()
    }

    @Test
    func cancellingDiscardOfAnEmptyLongSavedPadKeepsItsExactFileAndCheckpoint() async throws {
        let (directory, store, journal) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let confirmation = QuickNoteDiscardDecision()
        var deleted: MeetingNote?
        let pad = QuickNoteController(
            store: store,
            recovery: journal,
            deleteSavedNote: { note in deleted = note; return true },
            discardConfirmation: { confirmation.request() }
        )
        pad.text = "A longer saved note with enough original words that deleting all of them must still require confirmation."
        let saved = try #require(pad.saveIfNeeded())
        let file = try #require(saved.fileURL)
        let savedBytes = try Data(contentsOf: file)
        pad.text = ""
        #expect(pad.wordCount == 0)
        #expect(pad.saveIfNeeded() == nil)
        await journal.flush()
        let restarted = DraftJournal(directoryURL: journal.directoryURL)
        await restarted.scan()
        let checkpoint = try #require(restarted.recoveredDrafts.first)
        let checkpointFile = journal.directoryURL.appendingPathComponent("\(checkpoint.id.uuidString).json")
        let checkpointBytes = try Data(contentsOf: checkpointFile)

        pad.discardWithConfirmation()
        #expect(confirmation.requestCount == 1)
        #expect(deleted == nil)
        #expect(pad.canDiscard)
        #expect(pad.hasUnsavedFailure)
        #expect(pad.hasUnsavedEdits)
        await journal.flush()
        #expect(try Data(contentsOf: file) == savedBytes)
        #expect(try Data(contentsOf: checkpointFile) == checkpointBytes)

        confirmation.allowsDiscard = true
        pad.discardWithConfirmation()
        #expect(confirmation.requestCount == 2)
        #expect(deleted?.id == saved.id)
        #expect(deleted?.fileURL?.standardizedFileURL == file.standardizedFileURL)
        #expect(!pad.canDiscard)
        #expect(!pad.hasUnsavedFailure)
        await journal.flush()
        await restarted.scan()
        #expect(restarted.recoveredDrafts.isEmpty)
    }

    @Test
    func emptySavedDiscardStillRefusesCopiedLibrariesAndExternalChanges() async throws {
        let (directory, store, journal) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var deletionAttempts = 0
        let pad = QuickNoteController(
            store: store,
            recovery: journal,
            deleteSavedNote: { _ in deletionAttempts += 1; return true },
            discardConfirmation: { true }
        )
        pad.text = "Saved in the first folder."
        let saved = try #require(pad.saveIfNeeded())
        let file = try #require(saved.fileURL)
        let originalBytes = try Data(contentsOf: file)
        let originalLibrary = store.storageURL
        pad.text = ""
        #expect(pad.saveIfNeeded() == nil)

        let other = directory.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let copy = other.appendingPathComponent(file.lastPathComponent)
        try originalBytes.write(to: copy)
        store.storageURL = other
        #expect(pad.canDiscard)
        pad.discardWithConfirmation()
        #expect(deletionAttempts == 0)
        #expect(pad.canDiscard)
        #expect(pad.hasUnsavedFailure)
        #expect(try Data(contentsOf: file) == originalBytes)
        #expect(try Data(contentsOf: copy) == originalBytes)

        store.storageURL = originalLibrary
        let changedBytes = originalBytes + Data("\nExternal words".utf8)
        try changedBytes.write(to: file)
        pad.discardWithConfirmation()
        #expect(deletionAttempts == 0)
        #expect(pad.canDiscard)
        #expect(pad.hasUnsavedFailure)
        #expect(try Data(contentsOf: file) == changedBytes)
        await journal.flush()
    }

    @Test
    func deletingAnUnavailableOriginalDoesNotAuthorizeDraftCleanup() throws {
        let (directory, store, journal) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pad = QuickNoteController(store: store, recovery: journal)
        pad.text = "Original words."
        let saved = try #require(pad.saveIfNeeded())
        let file = try #require(saved.fileURL)
        try FileManager.default.removeItem(at: file)
        var cleanupWasAuthorized = false
        store.onNoteDeleted = { _ in cleanupWasAuthorized = true }
        #expect(!store.delete(saved))
        #expect(!cleanupWasAuthorized)
        journal.flushSynchronously()
    }

    @Test
    func deletionAlsoMatchesACompletedNewPadButNotACopiedLibrary() {
        let note = MeetingNote(
            title: "Synthetic note", startedAt: Date(), endedAt: Date(),
            sourceApp: "Test", summary: "Words",
            fileURL: URL(fileURLWithPath: "/synthetic/library/new.md")
        )
        let pendingCompletion = DraftCheckpoint(
            kind: .quickNote, libraryPath: "/synthetic/library",
            title: "Unfinished quick note", text: "Words",
            completion: DraftCompletion(
                targetPath: "/synthetic/library/new.md", noteID: note.id,
                revision: Data(repeating: 1, count: 32)
            )
        )
        let copiedLibrary = DraftCheckpoint(
            kind: .personalNotes, libraryPath: "/synthetic/other",
            originalFilePath: "/synthetic/other/new.md", noteID: note.id,
            title: "Other", text: "Unrelated words"
        )
        #expect(AppModel.recoveryIDs(forDeleted: note, in: [pendingCompletion, copiedLibrary]) == [pendingCompletion.id])
    }
}
