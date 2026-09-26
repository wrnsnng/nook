import Combine
import Foundation
import Testing
@testable import Nook

private actor DelayedQuickNoteAssistant {
    private var continuation: CheckedContinuation<String, Never>?
    private var queuedResult: String?
    private(set) var didStart = false
    private(set) var receivedEngines: [NoteAssistantEngine] = []
    private var startWaiters: [(Int, CheckedContinuation<Bool, Never>)] = []
    private var cancellationWasRequested = false
    private var cancellationWaiters: [CheckedContinuation<Bool, Never>] = []

    func nextResult(engine: NoteAssistantEngine = .onDevice) async -> String {
        didStart = true
        receivedEngines.append(engine)
        let ready = startWaiters.filter { $0.0 <= receivedEngines.count }
        startWaiters.removeAll { $0.0 <= receivedEngines.count }
        for (_, waiter) in ready { waiter.resume(returning: true) }
        if let queuedResult {
            self.queuedResult = nil
            return queuedResult
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
    }

    func release(_ result: String) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: result)
        } else {
            queuedResult = result
        }
    }

    func waitForStarts(_ minimum: Int) async -> Bool {
        if receivedEngines.count >= minimum { return true }
        return await withCheckedContinuation { startWaiters.append((minimum, $0)) }
    }

    func finish() {
        release("")
        let waiters = startWaiters
        startWaiters = []
        for (_, waiter) in waiters { waiter.resume(returning: false) }
        let cancelled = cancellationWaiters
        cancellationWaiters = []
        for waiter in cancelled { waiter.resume(returning: false) }
    }

    func waitForCancellation() async -> Bool {
        if cancellationWasRequested { return true }
        return await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    private func recordCancellation() {
        cancellationWasRequested = true
        let waiters = cancellationWaiters
        cancellationWaiters = []
        for waiter in waiters { waiter.resume(returning: true) }
    }
}

private enum DelayedQuickNoteAssistantError: Error {
    case failed
}

/// A filing test must never use the developer's Trash, including when a
/// regression unexpectedly reaches the successful move path.
private final class QuickNoteFilingFileManager: FileManager {
    let directory: URL
    let rejectsTrash: Bool
    private(set) var trashedURLs: [URL] = []

    init(directory: URL, rejectsTrash: Bool = false) {
        self.directory = directory
        self.rejectsTrash = rejectsTrash
        super.init()
    }

    override func trashItem(
        at url: URL,
        resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?
    ) throws {
        guard url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/") else {
            throw CocoaError(.fileWriteNoPermission)
        }
        trashedURLs.append(url)
        if rejectsTrash { throw CocoaError(.fileWriteNoPermission) }
        let trash = directory.appendingPathComponent("SimulatedTrash", isDirectory: true)
        try createDirectory(at: trash, withIntermediateDirectories: true)
        let destination = trash.appendingPathComponent(UUID().uuidString + ".md")
        try moveItem(at: url, to: destination)
        resultingItemURL?.pointee = destination as NSURL
    }
}

private actor DelayedQuickNoteFailure {
    private var continuation: CheckedContinuation<Void, Never>?
    private var releaseRequested = false
    private(set) var didStart = false

    func nextResult() async throws -> String {
        didStart = true
        if releaseRequested {
            throw DelayedQuickNoteAssistantError.failed
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        throw DelayedQuickNoteAssistantError.failed
    }

    func release() {
        if let continuation {
            self.continuation = nil
            continuation.resume()
        } else {
            releaseRequested = true
        }
    }
}

private actor ReorderedQuickNoteDiscovery {
    private var count = 0
    private var first: CheckedContinuation<[NoteAssistantEngine], Never>?
    private var firstStarted: CheckedContinuation<Bool, Never>?

    func load() async -> [NoteAssistantEngine] {
        count += 1
        guard count == 1 else { return [.codex] }
        return await withCheckedContinuation {
            first = $0
            firstStarted?.resume(returning: true)
            firstStarted = nil
        }
    }

    func waitForFirst() async -> Bool {
        if first != nil { return true }
        return await withCheckedContinuation { firstStarted = $0 }
    }

    func releaseFirst() {
        first?.resume(returning: [])
        first = nil
    }
}

/// The quick note pad is usually the only copy of something that was said out
/// loud a second ago. Two ways of ending it used to throw those words away
/// without saying anything: quitting inside the autosave debounce, and closing
/// after a save the store had refused.
@MainActor
struct QuickNotePadSafetyTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NookQuickNotePad-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    /// A saved note's content with the save stamp normalized.
    ///
    /// `saveIfNeeded()` always sets `endedAt` to the moment of the write, and
    /// the debounced autosave scheduled by setting `text` can legitimately
    /// rewrite the note while a test is still running. Comparing raw bytes
    /// therefore failed whenever those two writes straddled a second, which is
    /// why these tests flaked on CI and passed on faster machines. Only the
    /// stamp is normalized: the words, the title, and every other field still
    /// have to match exactly, which is what these tests are really asserting.
    private func savedContent(of file: URL) throws -> String {
        try String(contentsOf: file, encoding: .utf8).replacingOccurrences(
            of: "(?m)^ended: .*$",
            with: "ended: <written>",
            options: .regularExpression
        )
    }

    private func store(in directory: URL, fileManager: FileManager = .default) -> MarkdownStore {
        let store = MarkdownStore(fileManager: fileManager, noteLoader: { _, _ in
            .success((notes: [], issues: []))
        })
        store.storageURL = directory
        return store
    }

    private func filingStore(in directory: URL, fileManager: QuickNoteFilingFileManager) -> MarkdownStore {
        let root = fileManager.directory.standardizedFileURL.path + "/"
        let store = MarkdownStore(fileManager: fileManager, noteLoader: { directory, cache in
            // Initial construction may still carry the normal app preference.
            // This test loader only reads its own synthetic directories.
            guard directory.standardizedFileURL.path.hasPrefix(root) else {
                return .success((notes: [], issues: []))
            }
            return MarkdownStore.loadNotes(in: directory, cache: cache)
        })
        store.storageURL = directory
        return store
    }

    private func reloadFilingStore(_ store: MarkdownStore) async throws {
        store.reload()
        for _ in 0..<100 where store.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!store.isLoading, "The synthetic library should finish reloading.")
    }

    private func recoveredFilingDraft(in journal: DraftJournal) async throws -> DraftCheckpoint {
        await journal.flush()
        let restarted = DraftJournal(directoryURL: journal.directoryURL)
        await restarted.scan()
        try #require(restarted.recoveredDrafts.count == 1)
        return try #require(restarted.recoveredDrafts.first)
    }

    private func waitForAssistant(_ assistant: DelayedQuickNoteAssistant, starts: Int = 1) async throws {
        let started = await withDeadline(seconds: 5) { await assistant.waitForStarts(starts) }
        if started != true { await assistant.finish() }
        try #require(started == true, "The injected assistant should start without invoking a real provider.")
    }

    @Test
    func theDisplayedWordCountFollowsTypingDictationCorrectionAndClearing() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pad = QuickNoteController(store: store(in: directory))

        #expect(pad.wordCount == 0)
        pad.text = "Café\t👩🏽‍💻\nnext\u{00A0}step"
        try await waitForWordCount(pad)
        #expect(pad.wordCount == 4)
        pad.append("  confirm the plan  ")
        try await waitForWordCount(pad)
        #expect(pad.wordCount == 7)
        pad.replaceLastDictation(with: "confirmed", spoken: "confirm the plan")
        try await waitForWordCount(pad)
        #expect(pad.wordCount == 5)
        #expect(pad.text.hasSuffix("confirmed"))

        // A programmatic replacement may have the same byte length but a
        // different number of words, just as an ordinary correction can.
        pad.text = "one two"
        try await waitForWordCount(pad)
        #expect(pad.wordCount == 2)
        pad.text = "onetwox"
        try await waitForWordCount(pad)
        #expect(pad.wordCount == 1)
        pad.text = "\t \n"
        try await waitForWordCount(pad)
        #expect(pad.wordCount == 0)
        pad.text = ""
        #expect(pad.wordCount == 0)
    }

    private func waitForWordCount(_ pad: QuickNoteController) async throws {
        for _ in 0..<100 where pad.wordCount == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(pad.wordCount != nil)
    }

    /// An actual external edit, including on filesystems whose modification
    /// timestamp does not advance between two quick writes.
    private func markChangedElsewhere(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modified = try #require(attributes[.modificationDate] as? Date)
        let markdown = try String(contentsOf: url, encoding: .utf8)
        try (markdown + "\n## External review\nKeep these words from another editor.\n")
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: modified],
            ofItemAtPath: url.path
        )
    }

    @Test
    func quittingWritesWhatIsStillInThePad() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let pad = QuickNoteController(store: store)

        // Typed, with the debounce not yet due: exactly the state a quit lands
        // in most often.
        pad.text = "Tell Priya the mockups are ready."

        #expect(pad.saveForTermination() == nil)
        #expect(
            store.notes.first?.summary == "Tell Priya the mockups are ready."
        )
    }

    @Test
    func quittingIsBlockedWhenThePadsWordsCouldNotBeWritten() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let pad = QuickNoteController(store: store)

        pad.text = "First thought."
        #expect(pad.saveIfNeeded() != nil)
        let fileURL = try #require(store.notes.first?.fileURL)
        try markChangedElsewhere(fileURL)

        pad.text = "First thought. Second thought."

        // A reason, not nil: the caller quits only when this is nil.
        #expect(pad.saveForTermination() != nil)
        #expect(pad.hasUnsavedFailure)
        #expect(pad.text == "First thought. Second thought.")
    }

    @Test
    func aPadThatCouldNotSaveRefusesToClose() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let pad = QuickNoteController(store: store)

        pad.text = "Half of an idea."
        #expect(pad.saveIfNeeded() != nil)
        let fileURL = try #require(store.notes.first?.fileURL)
        try markChangedElsewhere(fileURL)

        pad.text = "Half of an idea, and the other half."

        #expect(!pad.canClose())
        pad.close()

        // The words are still on screen, with a reason beside them, rather
        // than gone with the window.
        #expect(pad.text == "Half of an idea, and the other half.")
        #expect(pad.message != nil)
        #expect(!pad.messageIsAdvisory)
    }

    @Test
    func aPadWithNothingInItClosesWithoutComplaint() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let pad = QuickNoteController(store: store)

        #expect(pad.canClose())
        #expect(pad.saveForTermination() == nil)
        #expect(store.notes.isEmpty)
    }

    @Test
    func aTrulyEmptyUnsavedPadHasNothingToDiscard() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var confirmations = 0
        var deletions = 0
        let pad = QuickNoteController(
            store: store(in: directory),
            deleteSavedNote: { _ in deletions += 1; return true },
            discardConfirmation: { confirmations += 1; return true }
        )

        #expect(!pad.canDiscard)
        pad.discardWithConfirmation()
        #expect(confirmations == 0)
        #expect(deletions == 0)
        #expect(!pad.canDiscard)
        #expect(pad.text.isEmpty)
    }

    @Test
    func undoingASavedPadToEmptyEnablesDiscardButStillRequiresConfirmation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var confirmations = 0
        var deletions = 0
        let pad = QuickNoteController(
            store: store(in: directory),
            deleteSavedNote: { _ in deletions += 1; return true },
            discardConfirmation: { confirmations += 1; return false }
        )
        pad.text = "A short saved thought."
        let saved = try #require(pad.saveIfNeeded())
        let file = try #require(saved.fileURL)
        let savedBytes = try Data(contentsOf: file)
        pad.text = ""
        #expect(pad.saveIfNeeded() == nil)

        #expect(pad.canDiscard)
        pad.discardWithConfirmation()
        #expect(confirmations == 1)
        #expect(deletions == 0)
        #expect(pad.canDiscard)
        #expect(pad.hasUnsavedFailure)
        #expect(try Data(contentsOf: file) == savedBytes)
    }

    @Test
    func confirmingAnEmptySavedPadDeletesItsExactOwnedNoteAndResetsThePad() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var deleted: MeetingNote?
        var confirmations = 0
        let pad = QuickNoteController(
            store: store(in: directory),
            deleteSavedNote: { note in deleted = note; return true },
            discardConfirmation: { confirmations += 1; return true }
        )
        pad.text = "The owned saved thought."
        let saved = try #require(pad.saveIfNeeded())
        pad.text = ""
        #expect(pad.saveIfNeeded() == nil)

        pad.discardWithConfirmation()
        #expect(confirmations == 1)
        #expect(deleted?.id == saved.id)
        #expect(deleted?.fileURL?.standardizedFileURL == saved.fileURL?.standardizedFileURL)
        #expect(pad.text.isEmpty)
        #expect(!pad.canDiscard)
        #expect(!pad.hasUnsavedFailure)
        #expect(!pad.hasUnsavedEdits)
        #expect(pad.message == nil)
    }

    @Test
    func failedDeletionKeepsAnEmptySavedPadEligibleWithItsOwnedFileIntact() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var deletions = 0
        let pad = QuickNoteController(
            store: store(in: directory),
            deleteSavedNote: { _ in deletions += 1; return false },
            discardConfirmation: { true }
        )
        pad.text = "The owned saved thought."
        let saved = try #require(pad.saveIfNeeded())
        let file = try #require(saved.fileURL)
        let savedBytes = try Data(contentsOf: file)
        pad.text = ""
        #expect(pad.saveIfNeeded() == nil)

        pad.discardWithConfirmation()
        #expect(deletions == 1)
        #expect(pad.canDiscard)
        #expect(pad.text.isEmpty)
        #expect(pad.hasUnsavedFailure)
        #expect(pad.hasUnsavedEdits)
        #expect(pad.message != nil)
        #expect(try Data(contentsOf: file) == savedBytes)
    }

    @Test(arguments: ["Original synthetic thought.", "Revised synthetic thought.", " \u{0301} "])
    func restoringNonemptyWordsClearsOnlyTheEmptyValidationBeforeAutosave(_ restored: String) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let pad = QuickNoteController(store: store)
        pad.text = "Original synthetic thought."
        let saved = try #require(pad.saveIfNeeded())
        let file = try #require(saved.fileURL)
        let originalContent = try savedContent(of: file)
        let savedAt = pad.lastSavedAt

        pad.text = ""
        #expect(pad.saveIfNeeded() == nil)
        #expect(pad.message != nil)
        #expect(pad.hasUnsavedFailure)

        // Redo or typing restores words. No autosave or view callback is run
        // here: the warning must stop describing the previous empty revision.
        pad.text = restored
        #expect(pad.message == nil)
        #expect(!pad.hasUnsavedFailure)
        #expect(pad.hasUnsavedEdits)
        #expect(pad.lastSavedAt == savedAt)
        #expect(Data(pad.text.utf8) == Data(restored.utf8))
        #expect(try savedContent(of: file) == originalContent)
        #expect(store.notes.first?.summary == saved.summary)
    }

    @Test
    func whitespaceEditsKeepTheEmptyValidationAndItsCloseProtection() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pad = QuickNoteController(store: store(in: directory))
        pad.text = "Original synthetic thought."
        _ = try #require(pad.saveIfNeeded())
        pad.text = ""
        #expect(pad.saveIfNeeded() == nil)
        let warning = try #require(pad.message)

        for whitespace in [" \t\r\n", "\u{00A0}\u{2003}", ""] {
            pad.text = whitespace
            #expect(pad.message == warning)
            #expect(pad.hasUnsavedFailure)
            #expect(pad.hasUnsavedEdits)
            #expect(!pad.canClose())
        }
    }

    @Test
    func aRealFileConflictIsNotClearedByLaterEmptyOrNonemptyEdits() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pad = QuickNoteController(store: store(in: directory))
        pad.text = "Original synthetic thought."
        let saved = try #require(pad.saveIfNeeded())
        let file = try #require(saved.fileURL)
        pad.text = ""
        #expect(pad.saveIfNeeded() == nil)
        pad.text = "Restored synthetic thought."
        #expect(pad.message == nil)

        try markChangedElsewhere(file)
        let externalBytes = try Data(contentsOf: file)
        #expect(pad.saveIfNeeded() == nil)
        let conflict = try #require(pad.message)
        for replacement in ["", "Another edit after the conflict."] {
            pad.text = replacement
            #expect(pad.message == conflict)
            #expect(pad.hasUnsavedFailure)
            #expect(pad.hasUnsavedEdits)
        }
        #expect(pad.saveForTermination() != nil)
        #expect(try Data(contentsOf: file) == externalBytes)
    }

    @Test
    func aFailedDiscardSupersedesEmptyValidationAndSurvivesRestoredWords() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pad = QuickNoteController(
            store: store(in: directory), deleteSavedNote: { _ in false }
        )
        pad.text = "Original synthetic thought."
        let saved = try #require(pad.saveIfNeeded())
        let file = try #require(saved.fileURL)
        let originalContent = try savedContent(of: file)
        pad.text = ""
        #expect(pad.saveIfNeeded() == nil)

        pad.discard()
        let failure = try #require(pad.message)
        pad.text = "Restored after the unsuccessful discard."
        #expect(pad.message == failure)
        #expect(pad.hasUnsavedFailure)
        #expect(pad.hasUnsavedEdits)
        #expect(try savedContent(of: file) == originalContent)
    }

    @Test
    func closingThePadEndsItsCaptureSession() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pad = QuickNoteController(store: store(in: directory))
        var dismissalCount = 0
        pad.onDismissRequested = { dismissalCount += 1 }
        pad.isContinuous = true

        pad.close()

        #expect(dismissalCount == 1)
        #expect(!pad.isContinuous)
    }

    @Test
    func aFailedDiscardKeepsTheSavedNoteAndItsWords() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let pad = QuickNoteController(
            store: store,
            deleteSavedNote: { _ in false }
        )
        pad.text = "Keep the pricing thought."
        #expect(pad.saveIfNeeded() != nil)

        pad.discard()

        #expect(pad.text == "Keep the pricing thought.")
        #expect(store.notes.count == 1)
        #expect(pad.hasUnsavedFailure)
        #expect(pad.message != nil)
    }

    @Test
    func aPadThatSavesOnTheSecondTryStopsBlockingTheClose() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let pad = QuickNoteController(store: store)

        pad.text = "One line."
        #expect(pad.saveIfNeeded() != nil)
        let saved = try #require(store.notes.first)
        let fileURL = try #require(saved.fileURL)
        let original = try Data(contentsOf: fileURL)
        try markChangedElsewhere(fileURL)

        pad.text = "One line, then another."
        #expect(!pad.canClose())

        // Whatever the file was doing has settled and it agrees with what Nook
        // last read, so the same words go through and the objection lifts.
        try original.write(to: fileURL, options: .atomic)
        #expect(pad.canClose())
        #expect(!pad.hasUnsavedFailure)
        #expect(store.notes.first?.summary == "One line, then another.")
    }

    @Test
    func reloadingAnExternalEditDoesNotAuthorizeThePadsNextAutosave() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MarkdownStore(noteLoader: { candidate, cache in
            guard candidate == directory else {
                return .success((notes: [], issues: []))
            }
            return MarkdownStore.loadNotes(in: candidate, cache: cache)
        })
        store.storageURL = directory
        let pad = QuickNoteController(store: store)
        pad.text = "First saved thought."
        let saved = try #require(pad.saveIfNeeded())
        let url = try #require(saved.fileURL)
        let modified = try #require(saved.fileModified)
        let markdown = try String(contentsOf: url, encoding: .utf8)
        let external = markdown.replacingOccurrences(
            of: "First saved thought.",
            with: "An external correction."
        )
        try external.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: modified],
            ofItemAtPath: url.path
        )
        pad.text = "First saved thought. More words from the pad."

        #expect(pad.saveIfNeeded() == nil)
        for _ in 0..<100 where store.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!store.isLoading)
        #expect(store.notes.first?.summary == "An external correction.")

        #expect(pad.saveIfNeeded() == nil)
        #expect(pad.hasUnsavedFailure)
        #expect(pad.text == "First saved thought. More words from the pad.")
        #expect(try String(contentsOf: url, encoding: .utf8) == external)
    }

    @Test
    func aDebouncedConflictKeepsThePadMarkedAsUnsaved() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let pad = QuickNoteController(store: store)
        pad.text = "An original thought."
        let saved = try #require(pad.saveIfNeeded())
        let file = try #require(saved.fileURL)
        try markChangedElsewhere(file)
        pad.text = "A later thought that must stay in the pad."
        pad.scheduleSave()
        for _ in 0..<100 where !pad.hasUnsavedFailure {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(pad.hasUnsavedFailure)
        #expect(pad.hasUnsavedEdits)
        #expect(pad.text == "A later thought that must stay in the pad.")
    }

    @Test
    func filingAConflictedPadCannotChangeTheTargetOrTrashNewerSourceWords() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = QuickNoteFilingFileManager(directory: directory)
        let store = store(in: directory, fileManager: files)
        let target = try store.save(MeetingNote(
            title: "Meeting target", startedAt: .now, endedAt: .now,
            sourceApp: "Test", summary: "Existing meeting.", personalNotes: "Original annotations."
        ))
        let targetFile = try #require(target.fileURL)
        let targetBytes = try Data(contentsOf: targetFile)
        let pad = QuickNoteController(store: store)
        pad.text = "A quick thought."
        let saved = try #require(pad.saveIfNeeded())
        let sourceFile = try #require(saved.fileURL)
        try markChangedElsewhere(sourceFile)
        let externalBytes = try Data(contentsOf: sourceFile)
        pad.text = "A quick thought with an unsaved addition."
        pad.fileIntoNote(target)
        #expect(pad.hasUnsavedFailure)
        #expect(pad.hasUnsavedEdits)
        #expect(pad.text == "A quick thought with an unsaved addition.")
        #expect(try Data(contentsOf: sourceFile) == externalBytes)
        #expect(try Data(contentsOf: targetFile) == targetBytes)
        #expect(files.trashedURLs.isEmpty)
    }

    @Test
    func filingOffersAllUniqueOwnedNotesAfterExcludingEverySharedID() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = directory.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let files = QuickNoteFilingFileManager(directory: directory)
        let store = filingStore(in: library, fileManager: files)
        let pad = QuickNoteController(store: store)
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        let copied = MeetingNote(
            title: "Copied meeting", startedAt: date.addingTimeInterval(60), endedAt: date,
            sourceApp: "Synthetic", summary: "Original copied meeting."
        )
        for index in 1...6 {
            try Data(MarkdownCodec.encode(copied).utf8)
                .write(to: library.appendingPathComponent("copy-\(index).md"))
        }
        // Equal dates intentionally arrive in the reverse of their stable
        // filename order; all six must remain available after reload.
        for index in (1...6).reversed() {
            let meeting = MeetingNote(
                title: "Review", startedAt: date, endedAt: date,
                sourceApp: "Synthetic", summary: "Independent meeting \(index)."
            )
            try Data(MarkdownCodec.encode(meeting).utf8)
                .write(to: library.appendingPathComponent("meeting-\(index).md"))
        }
        var publications = 0
        let observation = pad.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        try await reloadFilingStore(store)

        #expect(publications > 0, "An already-open filing popover must observe library changes.")
        #expect(pad.hasOmittedDuplicateNotes)
        #expect(pad.availableFilingTargets.count == 6)
        #expect(!pad.availableFilingTargets.contains { $0.id == copied.id })
        let choices = pad.filingChoices
        #expect(choices.compactMap(\.disambiguatingFilename) == (1...6).map { "meeting-\($0).md" })
        #expect(Set(choices.map(\.id)).count == 6)
        #expect(Set(choices.map(\.accessibilityLabel)).count == 6)
        #expect(choices.map(\.id) == pad.availableFilingTargets.map(\.libraryIdentity))
        try await reloadFilingStore(store)
        #expect(pad.filingChoices.map(\.id) == choices.map(\.id))
        #expect(files.trashedURLs.isEmpty)
    }

    @Test
    func filingCaptionsDisambiguateTheDisplayedMinuteWithoutClutteringDistinctChoices() {
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        func meeting(_ title: String, _ offset: TimeInterval, _ filename: String) -> MeetingNote {
            MeetingNote(
                title: title, startedAt: date.addingTimeInterval(offset), endedAt: date,
                sourceApp: "Synthetic", summary: "A synthetic meeting.",
                fileURL: URL(fileURLWithPath: "/synthetic-library/\(filename)")
            )
        }
        let first = meeting("Review", 0, "first.md")
        let sameMinute = meeting("Review", 1, "second.md")
        let differentTitle = meeting("Planning", 0, "third.md")
        let differentTime = meeting("Review", 3_600, "fourth.md")
        let choices = QuickNoteFilingChoice.choices(for: [first, sameMinute, differentTitle, differentTime])

        #expect(choices[0].dateLabel == choices[1].dateLabel)
        #expect(choices[0].disambiguatingFilename == "first.md")
        #expect(choices[1].disambiguatingFilename == "second.md")
        #expect(choices[2].disambiguatingFilename == nil)
        #expect(choices[3].disambiguatingFilename == nil)
        #expect(choices[0].accessibilityLabel.contains("first.md"))
        #expect(choices[1].accessibilityLabel.contains("second.md"))
        #expect(Set(choices.map(\.accessibilityLabel)).count == 4)
    }

    @Test
    func aCopyAppearingAfterFilingSelectionPreservesThePadAndItsExactRecoveryBaseline() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = directory.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let files = QuickNoteFilingFileManager(directory: directory)
        let store = filingStore(in: library, fileManager: files)
        let journal = DraftJournal(directoryURL: directory.appendingPathComponent("Drafts"))
        let target = try store.save(MeetingNote(
            title: "Meeting target", startedAt: .now, endedAt: .now,
            sourceApp: "Synthetic", summary: "Existing meeting.", personalNotes: "Original notes."
        ))
        let targetFile = try #require(target.fileURL)
        let targetBytes = try Data(contentsOf: targetFile)
        var reviews = 0
        var dismissals = 0
        let pad = QuickNoteController(
            store: store, recovery: journal, openFilingLibrary: { reviews += 1 }
        )
        pad.onDismissRequested = { dismissals += 1 }
        pad.text = "An already saved thought."
        let saved = try #require(pad.saveIfNeeded())
        let sourceFile = try #require(saved.fileURL)
        let sourceBytes = try Data(contentsOf: sourceFile)
        pad.text = "  An unsaved Cafe\u{0301} thought.\r\n\n"
        let exactText = Data(pad.text.utf8)
        let checkpoint = try await recoveredFilingDraft(in: journal)
        let revision = pad.textRevision
        let lastSavedAt = pad.lastSavedAt
        let hasUnsavedEdits = pad.hasUnsavedEdits
        #expect(pad.availableFilingTargets.contains { $0.libraryIdentity == target.libraryIdentity })

        let copy = library.appendingPathComponent("copied-meeting.md")
        try targetBytes.write(to: copy)
        try await reloadFilingStore(store)
        pad.fileIntoNote(target)

        #expect(pad.hasOmittedDuplicateNotes)
        #expect(pad.availableFilingTargets.isEmpty)
        #expect(pad.message?.contains("shares its note ID") == true)
        #expect(Data(pad.text.utf8) == exactText)
        #expect(pad.textRevision == revision)
        #expect(pad.lastSavedAt == lastSavedAt)
        #expect(pad.hasUnsavedEdits == hasUnsavedEdits)
        #expect(try Data(contentsOf: sourceFile) == sourceBytes)
        #expect(try Data(contentsOf: targetFile) == targetBytes)
        #expect(try Data(contentsOf: copy) == targetBytes)
        let retained = try await recoveredFilingDraft(in: journal)
        #expect(retained.id == checkpoint.id)
        #expect(Data(retained.text.utf8) == exactText)
        #expect(Data(retained.baseline.utf8) == Data(checkpoint.baseline.utf8))
        #expect(retained.baselineRevision == saved.fileRevision)
        #expect(retained.completion == nil)

        // Reviewing the copies is deliberately not the existing save-and-open
        // command: it works without advancing the pad's save baseline.
        pad.reviewFilingTargetsInLibrary()
        #expect(reviews == 1)
        #expect(dismissals == 0)
        #expect(Data(pad.text.utf8) == exactText)
        #expect(pad.textRevision == revision)
        #expect(pad.lastSavedAt == lastSavedAt)
        #expect(try Data(contentsOf: sourceFile) == sourceBytes)
        #expect(files.trashedURLs.isEmpty)

        try markChangedElsewhere(sourceFile)
        let externalSource = try Data(contentsOf: sourceFile)
        #expect(pad.saveIfNeeded() == nil, "A refused filing must not rebind the saved pad's original revision.")
        #expect(pad.hasUnsavedFailure)
        #expect(try Data(contentsOf: sourceFile) == externalSource)
        #expect(Data(pad.text.utf8) == exactText)
    }

    @Test(arguments: ["removed", "moved", "changed", "folder"])
    func filingRevalidatesTheCapturedFileWithoutRebindingThePad(change: String) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = directory.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let files = QuickNoteFilingFileManager(directory: directory)
        let store = filingStore(in: library, fileManager: files)
        let journal = DraftJournal(directoryURL: directory.appendingPathComponent("Drafts"))
        let target = try store.save(MeetingNote(
            title: "Meeting target", startedAt: .now, endedAt: .now,
            sourceApp: "Synthetic", summary: "Existing meeting.", personalNotes: "Original notes."
        ))
        let targetFile = try #require(target.fileURL)
        var survivingTarget: URL? = targetFile
        let pad = QuickNoteController(store: store, recovery: journal)
        pad.text = "Saved source."
        let saved = try #require(pad.saveIfNeeded())
        let source = try #require(saved.fileURL)
        let sourceBytes = try Data(contentsOf: source)
        pad.text = "  Keep my Cafe\u{0301} revision.\r\n"
        let exactText = Data(pad.text.utf8)
        let checkpoint = try await recoveredFilingDraft(in: journal)
        let lastSavedAt = pad.lastSavedAt

        switch change {
        case "removed":
            try FileManager.default.removeItem(at: targetFile)
            survivingTarget = nil
        case "moved":
            let moved = library.appendingPathComponent("moved-target.md")
            try FileManager.default.moveItem(at: targetFile, to: moved)
            survivingTarget = moved
        case "changed":
            // The personal field is unchanged. A fresher loaded revision must
            // still not authorize a target offered before this external edit.
            try markChangedElsewhere(targetFile)
        default:
            let other = directory.appendingPathComponent("OtherLibrary", isDirectory: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            store.storageURL = other
        }
        try await reloadFilingStore(store)
        let targetBytes = try survivingTarget.map { try Data(contentsOf: $0) }
        pad.fileIntoNote(target)

        #expect(pad.message != nil)
        #expect(Data(pad.text.utf8) == exactText)
        #expect(pad.lastSavedAt == lastSavedAt)
        #expect(try Data(contentsOf: source) == sourceBytes)
        #expect(try survivingTarget.map { try Data(contentsOf: $0) } == targetBytes)
        let retained = try await recoveredFilingDraft(in: journal)
        #expect(retained.id == checkpoint.id)
        #expect(Data(retained.text.utf8) == exactText)
        #expect(Data(retained.baseline.utf8) == Data(checkpoint.baseline.utf8))
        #expect(retained.baselineRevision == saved.fileRevision)
        #expect(retained.libraryPath == checkpoint.libraryPath)
        #expect(files.trashedURLs.isEmpty)
    }

    @Test
    func oldCodexConsentCannotAuthorizeTheBroaderFileAccessDisclosure() throws {
        let suite = "NookConsentTest-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("codex", forKey: "quickNoteEngine")
        defaults.set(true, forKey: "quickNoteConsent.codex")
        #expect(QuickNoteController.restoredEngine(defaults: defaults) == .onDevice)
        #expect(defaults.string(forKey: "quickNoteEngine") == "onDevice")
        defaults.set("codex", forKey: "quickNoteEngine")
        defaults.set(true, forKey: "quickNoteConsent.codex.v2")
        #expect(QuickNoteController.restoredEngine(defaults: defaults) == .codex)
        defaults.set("claude", forKey: "quickNoteEngine")
        defaults.set(true, forKey: "quickNoteConsent.claude")
        #expect(QuickNoteController.restoredEngine(defaults: defaults) == .claude)
    }

    @Test(arguments: [NoteAssistantEngine.claude, .codex])
    func aSoleUnapprovedExternalAssistantRemainsChoosableWithoutEnablingUnavailableLocalActions(
        _ external: NoteAssistantEngine
    ) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "NookAssistantAvailability-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let assistant = DelayedQuickNoteAssistant()
        let pad = QuickNoteController(
            store: store(in: directory),
            assistantRun: { _, _, engine in await assistant.nextResult(engine: engine) },
            availableEngines: { [external] },
            defaults: defaults
        )
        await pad.refreshEngines().value
        pad.text = "Keep this local draft exactly as written."

        #expect(pad.engine == .onDevice)
        #expect(pad.canChooseAssistant)
        #expect(!pad.isSelectedAssistantAvailable)
        #expect(!pad.canRunAction)
        #expect(!pad.hasConsented(to: external))
        #expect(pad.actionStatusDescription.contains("unavailable"))
        #expect(pad.outboundEngine == nil)
        let refused = pad.run(.summarize)
        #expect(refused == nil)
        await assistant.release(pad.text)
        await refused?.value
        #expect(await assistant.receivedEngines.isEmpty)

        // Optional assistance must not prevent ordinary local saving or grant
        // permission merely because only one installed alternative exists.
        let saved = try #require(pad.saveIfNeeded())
        #expect(saved.summary.utf8.elementsEqual(pad.text.utf8))
        #expect(!pad.hasConsented(to: external))
        #expect(pad.engine == .onDevice)
    }

    @Test(arguments: [false, true])
    func stoppingAnExternalActionKeepsItsDisclosureUntilAnIgnoringAssistantReturns(
        revokeConsent: Bool
    ) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "NookAssistantStopping-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("codex", forKey: "quickNoteEngine")
        defaults.set(true, forKey: "quickNoteConsent.codex.v2")
        let assistant = DelayedQuickNoteAssistant()
        let pad = QuickNoteController(
            store: store(in: directory),
            assistantRun: { _, _, engine in await assistant.nextResult(engine: engine) },
            availableEngines: { [.onDevice, .codex] },
            defaults: defaults
        )
        pad.present()
        await pad.refreshEngines().value
        let original = "Review the launch plan."
        pad.text = original
        let saved = try #require(pad.saveIfNeeded())
        let file = try #require(saved.fileURL)
        let originalContent = try savedContent(of: file)
        let operation = try #require(pad.run(.summarize))
        try await waitForAssistant(assistant)
        #expect(pad.runningEngine == .codex)
        #expect(pad.actionStatusDescription.contains("Summarise"))
        #expect(pad.actionStatusDescription.contains("Codex"))
        #expect(!pad.actionAvailabilityHint.contains("Choose an action"))

        if revokeConsent {
            pad.revokeConsent(for: .codex)
        } else {
            pad.selectEngine(.onDevice)
        }
        #expect(pad.engine == .onDevice)
        #expect(pad.isWorking && pad.isStoppingAssistant)
        #expect(pad.runningEngine == .codex)
        #expect(pad.outboundEngine == .codex)
        #expect(pad.outboundMessage.contains("Stopping Codex"))
        #expect(pad.outboundMessage.contains("OpenAI"))
        #expect(pad.outboundMessage.contains("file access"))
        #expect(!pad.canRunAction)
        #expect(pad.run(.tidy) == nil)
        #expect(pad.hasConsented(to: .codex) == !revokeConsent)
        #expect(pad.text.utf8.elementsEqual(original.utf8))
        #expect(try savedContent(of: file) == originalContent)

        // This supported summary would append to unchanged input if accepted.
        // The fake deliberately ignores cancellation and returns it anyway.
        await assistant.release(original)
        await operation.value
        #expect(!pad.isWorking && !pad.isStoppingAssistant)
        #expect(pad.runningAction == nil && pad.runningEngine == nil)
        #expect(pad.outboundEngine == nil && pad.outboundMessage.isEmpty)
        #expect(pad.canRunAction)
        #expect(pad.text.utf8.elementsEqual(original.utf8))
        #expect(try savedContent(of: file) == originalContent)
        pad.text += " Keep the cafe\u{301} notes."
        let laterSave = try #require(pad.saveIfNeeded())
        #expect(laterSave.summary.utf8.elementsEqual(pad.text.utf8))
        pad.close()
    }

    @Test
    func changingProvidersDoesNotRelabelAnOldRunOrAllowOverlappingActions() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "NookAssistantHandoff-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("codex", forKey: "quickNoteEngine")
        defaults.set(true, forKey: "quickNoteConsent.codex.v2")
        defaults.set(true, forKey: "quickNoteConsent.claude")
        let assistant = DelayedQuickNoteAssistant()
        let pad = QuickNoteController(
            store: store(in: directory),
            assistantRun: { _, _, engine in await assistant.nextResult(engine: engine) },
            availableEngines: { [.onDevice, .claude, .codex] },
            defaults: defaults
        )
        pad.present()
        await pad.refreshEngines().value
        pad.text = "Review the launch plan."
        let first = try #require(pad.run(.summarize))
        try await waitForAssistant(assistant)
        pad.selectEngine(.claude)
        #expect(pad.engine == .claude)
        #expect(pad.runningEngine == .codex)
        #expect(pad.outboundEngine == .codex)
        #expect(pad.actionStatusDescription.contains("Codex"))
        #expect(pad.run(.tidy) == nil)
        await assistant.release(pad.text)
        await first.value
        #expect(pad.outboundEngine == .claude)
        #expect(pad.canRunAction)

        let second = try #require(pad.run(.tidy))
        try await waitForAssistant(assistant, starts: 2)
        #expect(await assistant.receivedEngines == [.codex, .claude])
        #expect(pad.runningAction == .tidy && pad.runningEngine == .claude)
        #expect(pad.isWorking && !pad.isStoppingAssistant)
        pad.selectEngine(.onDevice)
        await assistant.release(pad.text)
        await second.value
        #expect(pad.text == "Review the launch plan.")
        pad.close()
    }

    @Test
    func keepingWorkLocalSurvivesDiscoveryAndAReopenedPadEvenWithPriorExternalConsent() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "NookKeepLocal-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("codex", forKey: "quickNoteEngine")
        defaults.set(true, forKey: "quickNoteConsent.codex.v2")
        let pad = QuickNoteController(
            store: store(in: directory), availableEngines: { [.codex] }, defaults: defaults
        )
        await pad.refreshEngines().value
        #expect(pad.engine == .codex)
        pad.selectEngine(.onDevice)
        await pad.refreshEngines().value
        #expect(pad.engine == .onDevice)
        #expect(pad.hasConsented(to: .codex))
        #expect(pad.canChooseAssistant)
        #expect(!pad.isSelectedAssistantAvailable)

        let reopened = QuickNoteController(
            store: store(in: directory), availableEngines: { [.codex] }, defaults: defaults
        )
        await reopened.refreshEngines().value
        #expect(reopened.engine == .onDevice)
        #expect(reopened.canChooseAssistant)
        #expect(!reopened.canRunAction)
        #expect(reopened.outboundEngine == nil)
        reopened.selectEngine(.codex)
        #expect(reopened.engine == .codex)
        #expect(reopened.hasConsented(to: .codex))
    }

    @Test
    func olderDiscoveryCannotCancelAnActionStartedFromANewerAvailableEngineList() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "NookAssistantDiscovery-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("codex", forKey: "quickNoteEngine")
        defaults.set(true, forKey: "quickNoteConsent.codex.v2")
        let discovery = ReorderedQuickNoteDiscovery()
        let assistant = DelayedQuickNoteAssistant()
        let pad = QuickNoteController(
            store: store(in: directory),
            assistantRun: { _, _, engine in await assistant.nextResult(engine: engine) },
            availableEngines: { await discovery.load() },
            defaults: defaults
        )
        let first = pad.refreshEngines()
        let started = await withDeadline(seconds: 5) { await discovery.waitForFirst() }
        try #require(started == true)
        await pad.refreshEngines().value
        pad.text = "Review the launch plan."
        let action = try #require(pad.run(.summarize))
        try await waitForAssistant(assistant)
        await discovery.releaseFirst()
        await first.value
        #expect(pad.availableEngines == [.codex])
        #expect(pad.engine == .codex && pad.runningEngine == .codex)
        #expect(pad.isWorking && !pad.isStoppingAssistant)
        pad.selectEngine(.onDevice)
        await assistant.release(pad.text)
        await action.value
    }

    @Test
    func keepingWorkLocalBeforeTheAssistantStartsPreventsItsInvocation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "NookAssistantNotStarted-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("codex", forKey: "quickNoteEngine")
        defaults.set(true, forKey: "quickNoteConsent.codex.v2")
        let assistant = DelayedQuickNoteAssistant()
        let pad = QuickNoteController(
            store: store(in: directory),
            assistantRun: { _, _, engine in await assistant.nextResult(engine: engine) },
            availableEngines: { [.codex] },
            defaults: defaults
        )
        await pad.refreshEngines().value
        pad.text = "Review the launch plan."
        let action = try #require(pad.run(.summarize))
        // Both synchronous calls run on the main actor before the new task
        // gets a chance to pass any text to the injected assistant.
        pad.selectEngine(.onDevice)
        await assistant.release(pad.text)
        await action.value
        #expect(await assistant.receivedEngines.isEmpty)
        #expect(!pad.isWorking && !pad.isStoppingAssistant)
        #expect(pad.outboundEngine == nil)
        #expect(pad.text == "Review the launch plan.")
    }

    @Test
    func quittingWaitsForAssistantCleanupAndKeepsNewActionsGatedAfterItFinishes() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "NookAssistantQuit-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("codex", forKey: "quickNoteEngine")
        defaults.set(true, forKey: "quickNoteConsent.codex.v2")
        let assistant = DelayedQuickNoteAssistant()
        let pad = QuickNoteController(
            store: store(in: directory),
            assistantRun: { _, _, engine in await assistant.nextResult(engine: engine) },
            availableEngines: { [.codex] },
            defaults: defaults
        )
        pad.present()
        await pad.refreshEngines().value
        pad.text = "Review the launch plan."
        let saved = try #require(pad.saveIfNeeded())
        let file = try #require(saved.fileURL)
        let originalContent = try savedContent(of: file)
        let action = try #require(pad.run(.summarize))
        try await waitForAssistant(assistant)

        let termination = Task { @MainActor in
            await pad.prepareAssistantForTermination()
        }
        let cancellation = await withDeadline(seconds: 5) { await assistant.waitForCancellation() }
        if cancellation != true { await assistant.finish() }
        try #require(cancellation == true)
        #expect(pad.isPreparingForTermination && pad.isStoppingAssistant)
        #expect(pad.isWorking && pad.outboundEngine == .codex)
        #expect(pad.outboundMessage.contains("Stopping Codex"))
        #expect(pad.run(.tidy) == nil)

        await assistant.release(pad.text)
        let mayQuit = await termination.value
        await action.value
        #expect(mayQuit)
        #expect(!pad.isWorking && pad.runningEngine == nil)
        #expect(pad.isPreparingForTermination)
        #expect(!pad.canRunAction)
        #expect(pad.run(.tidy) == nil)
        #expect(pad.text == "Review the launch plan.")
        #expect(try savedContent(of: file) == originalContent)

        pad.cancelApplicationTermination()
        #expect(!pad.isPreparingForTermination && pad.canRunAction)
        pad.close()
    }

    @Test
    func assistantCleanupTimeoutRefusesQuitWithoutErasingTheStoppingWarningOrAcceptingLateText() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "NookAssistantQuitTimeout-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("codex", forKey: "quickNoteEngine")
        defaults.set(true, forKey: "quickNoteConsent.codex.v2")
        let assistant = DelayedQuickNoteAssistant()
        let pad = QuickNoteController(
            store: store(in: directory),
            assistantRun: { _, _, engine in await assistant.nextResult(engine: engine) },
            availableEngines: { [.codex] },
            defaults: defaults
        )
        pad.present()
        await pad.refreshEngines().value
        pad.text = "Review the launch plan."
        let saved = try #require(pad.saveIfNeeded())
        let file = try #require(saved.fileURL)
        let originalContent = try savedContent(of: file)
        let action = try #require(pad.run(.summarize))
        try await waitForAssistant(assistant)

        // A zero deadline is deterministic because the injected operation is
        // still held by its continuation, not by an arbitrary wall-clock sleep.
        let mayQuit = await pad.prepareAssistantForTermination(timeout: 0)
        #expect(!mayQuit)
        #expect(pad.isPreparingForTermination && pad.isStoppingAssistant)
        #expect(pad.runningEngine == .codex && pad.outboundEngine == .codex)
        #expect(pad.outboundMessage.contains("Stopping Codex"))
        pad.cancelApplicationTermination()
        #expect(!pad.isPreparingForTermination)
        #expect(pad.isWorking && !pad.canRunAction)
        #expect(pad.run(.tidy) == nil)
        await assistant.release(pad.text)
        await action.value
        #expect(!pad.isWorking && !pad.isStoppingAssistant)
        #expect(pad.text == "Review the launch plan.")
        #expect(try savedContent(of: file) == originalContent)
        #expect(pad.canRunAction)
        pad.close()
    }

    @Test
    func delayedAssistantOutputCannotReplaceWordsEditedWhileItWasThinking() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let assistant = DelayedQuickNoteAssistant()
        let pad = QuickNoteController(
            store: store,
            assistantRun: { _, _, _ in await assistant.nextResult() },
            availableEngines: { [.onDevice] }
        )

        pad.present()
        await pad.refreshEngines().value
        pad.text = "The words I just said are the source of truth."
        pad.run(.tidy)
        for _ in 0..<100 {
            if await assistant.didStart { break }
            await Task.yield()
        }
        #expect(await assistant.didStart)

        pad.text = "I edited this while the assistant was thinking."
        await assistant.release("A stale rewrite")
        for _ in 0..<20 { await Task.yield() }

        #expect(pad.text == "I edited this while the assistant was thinking.")
        #expect(!pad.hasUnsavedFailure)
        pad.close()
    }

    @Test
    func delayedAssistantOutputCannotLandAfterThePadIsClosedAndReopened() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let assistant = DelayedQuickNoteAssistant()
        let pad = QuickNoteController(
            store: store,
            assistantRun: { _, _, _ in await assistant.nextResult() },
            availableEngines: { [.onDevice] }
        )

        pad.present()
        await pad.refreshEngines().value
        pad.text = "The first presentation should not receive old output."
        pad.run(.tidy)
        for _ in 0..<100 {
            if await assistant.didStart { break }
            await Task.yield()
        }
        #expect(await assistant.didStart)

        pad.close()
        pad.present()
        pad.text = "This is a new presentation."
        await assistant.release("Output from the old presentation")
        for _ in 0..<20 { await Task.yield() }

        #expect(pad.text == "This is a new presentation.")
        pad.close()
    }

    @Test
    func delayedAssistantFailureCannotSurfaceAfterDiscard() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let continuation = DelayedQuickNoteFailure()
        let pad = QuickNoteController(
            store: store,
            assistantRun: { _, _, _ in try await continuation.nextResult() },
            availableEngines: { [.onDevice] }
        )

        pad.present()
        await pad.refreshEngines().value
        pad.text = "This thought is being discarded."
        pad.run(.tidy)
        for _ in 0..<100 {
            if await continuation.didStart { break }
            await Task.yield()
        }
        #expect(await continuation.didStart)

        pad.discard()
        await continuation.release()
        for _ in 0..<20 { await Task.yield() }

        #expect(pad.text.isEmpty)
        #expect(pad.message == nil)
        #expect(!pad.isPresenting)
    }

    @Test
    func filingIntoAMeetingTakesTheAutosavedCopyWithIt() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = QuickNoteFilingFileManager(directory: directory)
        let store = store(in: directory, fileManager: files)
        let meeting = try store.save(
            MeetingNote(
                title: "Launch review",
                startedAt: Date(timeIntervalSince1970: 1_780_000_000),
                endedAt: Date(timeIntervalSince1970: 1_780_003_600),
                sourceApp: "Zoom",
                summary: "The team agreed on the launch scope."
            )
        )
        let pad = QuickNoteController(store: store)

        pad.text = "Ask Ana whether the beta list is final."
        // What the debounced autosave has usually already done by the time
        // anybody reaches the filing menu.
        #expect(pad.saveIfNeeded() != nil)
        let autosaved = try #require(store.notes.first { $0.kind == .spoken })
        let autosavedFile = try #require(autosaved.fileURL)

        pad.fileIntoNote(meeting)

        // Filing is a move, not a copy: one thought, in one place.
        #expect(!store.notes.contains { $0.id == autosaved.id })
        #expect(!FileManager.default.fileExists(atPath: autosavedFile.path))
        #expect(files.trashedURLs == [autosavedFile])
        #expect(
            store.notes.first { $0.id == meeting.id }?.personalNotes
                == "Ask Ana whether the beta list is final."
        )
    }

    @Test(arguments: [NoteKind.meeting, .spoken, .digest])
    func filingCanAppendToEveryKindWithoutReplacingExistingWords(kind: NoteKind) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = QuickNoteFilingFileManager(directory: directory)
        let store = store(in: directory, fileManager: files)
        var target = try store.save(MeetingNote(
            kind: kind, title: "Older destination", startedAt: .distantPast, endedAt: .distantPast,
            sourceApp: "Synthetic", summary: "Original Café body.",
            personalNotes: kind == .spoken ? "" : "Original annotation."
        ))
        if kind == .spoken {
            let raw = try store.rawMarkdown(for: target)
            let custom = raw.replacingOccurrences(of: "kind: spoken", with: "kind: spoken\ncustom-field: untouched")
                + "\n\n## Unknown user heading\n\nLeave this source as written.\r\n"
            try store.saveRawMarkdown(custom, for: target)
            target = try #require(store.note(matching: target.libraryIdentity))
        }
        let before = try store.rawMarkdown(for: target)
        let pad = QuickNoteController(store: store)
        let words = "A new Cafe\u{0301} thought.\r\nSecond line 👩🏽‍💻."
        pad.text = words
        let autosaved = try #require(pad.saveIfNeeded())
        #expect(pad.availableFilingTargets.contains { $0.libraryIdentity == target.libraryIdentity })
        #expect(!pad.availableFilingTargets.contains { $0.libraryIdentity == autosaved.libraryIdentity })
        #expect(pad.fileIntoNote(target))
        let persisted = try #require(store.note(matching: target.libraryIdentity))
        if kind == .spoken {
            let after = try store.rawMarkdown(for: persisted)
            #expect(Array(after.utf8.prefix(before.utf8.count)) == Array(before.utf8))
            #expect(after.utf8.suffix(words.utf8.count).elementsEqual(words.utf8))
        } else {
            #expect(persisted.summary == target.summary)
            #expect(persisted.personalNotes.utf8.elementsEqual("Original annotation.\n\n\(words)".utf8))
        }
        #expect(persisted.id == target.id)
        #expect(persisted.title == target.title)
        #expect(files.trashedURLs == [autosaved.fileURL!])
        #expect(!store.notes.contains { $0.id == autosaved.id })
        #expect(pad.text.isEmpty)
        #expect(!pad.fileIntoNote(persisted), "Repeated callbacks cannot append the same completed pad twice.")
    }

    @Test
    func doneOffersFilingWithoutWritingAndCancelDoesNotRestartCapture() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let target = try store.save(MeetingNote(
            title: "Existing", startedAt: .now, endedAt: .now,
            sourceApp: "Synthetic", summary: "Original body."
        ))
        let bytes = try Data(contentsOf: target.fileURL!)
        let pad = QuickNoteController(store: store)
        var captureStops = 0
        pad.onDismissRequested = { captureStops += 1 }
        pad.text = "An unfinished thought."
        pad.isContinuous = true
        pad.done()
        let request = try #require(pad.filingRequest)
        #expect(request.choices.map(\.id) == [target.libraryIdentity])
        #expect(!pad.isContinuous)
        #expect(captureStops == 1)
        #expect(store.notes.count == 1)
        pad.done()
        #expect(pad.filingRequest?.id == request.id)
        #expect(captureStops == 1)
        pad.filingRequest = nil
        #expect(!pad.isContinuous)
        #expect(pad.text == "An unfinished thought.")
        #expect(try Data(contentsOf: target.fileURL!) == bytes)
        pad.close()
        #expect(!pad.hasUnsavedFailure)
        #expect(store.notes.count == 2)
        #expect(try Data(contentsOf: target.fileURL!) == bytes)
    }

    @Test
    func filingCannotAppendThePadToItsOwnAutosavedFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = QuickNoteFilingFileManager(directory: directory)
        let store = store(in: directory, fileManager: files)
        let pad = QuickNoteController(store: store)
        pad.text = "Keep this thought."
        let own = try #require(pad.saveIfNeeded())
        let before = try Data(contentsOf: own.fileURL!)
        #expect(!pad.fileIntoNote(own))
        #expect(pad.text == "Keep this thought.")
        #expect(try Data(contentsOf: own.fileURL!) == before)
        #expect(files.trashedURLs.isEmpty)
    }

    @Test
    func aSpokenDestinationChangedAfterThePickerOpenedRemainsUntouched() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = QuickNoteFilingFileManager(directory: directory)
        let store = store(in: directory, fileManager: files)
        let target = try store.save(MeetingNote(
            kind: .spoken, title: "Destination", startedAt: .now, endedAt: .now,
            sourceApp: "Synthetic", summary: "Original words."
        ))
        let pad = QuickNoteController(store: store)
        pad.text = "A new thought."
        pad.requestFiling()
        let stale = try #require(pad.filingRequest?.choices.first?.note)
        let file = try #require(target.fileURL)
        let external = try store.rawMarkdown(for: target) + "\nExternal words."
        try Data(external.utf8).write(to: file)
        #expect(!pad.fileIntoNote(stale))
        #expect(try Data(contentsOf: file) == Data(external.utf8))
        #expect(pad.text == "A new thought.")
        #expect(pad.filingRequest != nil)
        #expect(files.trashedURLs.isEmpty)
    }

    @Test
    func failedFilingTrashKeepsItsNoticeAndStartsAnIndependentNextDraft() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = QuickNoteFilingFileManager(directory: directory, rejectsTrash: true)
        let store = store(in: directory, fileManager: files)
        let journal = DraftJournal(directoryURL: directory.appendingPathComponent("Drafts"))
        let target = try store.save(MeetingNote(
            title: "Synthetic filing target", startedAt: .now, endedAt: .now,
            sourceApp: "Synthetic", summary: "A saved meeting.", personalNotes: "Existing annotation."
        ))
        let targetFile = try #require(target.fileURL)
        let suite = "NookFilingCompletionTest-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var reviews = 0
        var stoppedCaptureSessions = 0
        let pad = QuickNoteController(
            store: store, recovery: journal, defaults: defaults,
            openFilingLibrary: { reviews += 1 }
        )
        pad.onDismissRequested = { stoppedCaptureSessions += 1 }
        pad.text = "First saved thought."
        let saved = try #require(pad.saveIfNeeded())
        let sourceFile = try #require(saved.fileURL)
        let filedWords = "First saved thought. Keep the Cafe\u{0301} follow-up."
        pad.text = filedWords
        let priorDraft = try await recoveredFilingDraft(in: journal)

        pad.fileIntoNote(target)

        let notice = try #require(pad.filingCompletionMessage)
        #expect(notice.contains("Filed successfully"))
        #expect(notice.contains("couldn’t move"))
        #expect(pad.message == nil)
        #expect(pad.text.isEmpty)
        #expect(!pad.hasUnsavedFailure)
        #expect(!pad.hasUnsavedEdits)
        #expect(pad.lastSavedAt == nil)
        #expect(!pad.canDiscard)
        #expect(stoppedCaptureSessions == 1, "The completed filing ends its old capture even though the pad stays available.")
        #expect(files.trashedURLs == [sourceFile])
        let sourceBytes = try Data(contentsOf: sourceFile)
        let source = try #require(MarkdownCodec.decode(String(decoding: sourceBytes, as: UTF8.self)))
        #expect(source.id == saved.id)
        #expect(Data(source.summary.utf8) == Data(filedWords.utf8))
        let targetBytes = try Data(contentsOf: targetFile)
        let filedTarget = try #require(store.note(matching: target.libraryIdentity))
        #expect(Data(filedTarget.personalNotes.utf8) == Data("Existing annotation.\n\n\(filedWords)".utf8))
        #expect(store.notes.contains { $0.libraryIdentity == saved.libraryIdentity })
        let rows = QuickNotePadLayout.rows(
            outboundProvider: nil, notice: pad.filingCompletionMessage, noticeIsFailure: true,
            hearing: nil, hasSuggestion: false, hasAssistant: true
        )
        #expect(rows.contains(.notice(text: notice, isFailure: true)))

        // A repeated filing attempt or an empty autosave cannot duplicate the
        // append, dismiss the explanation, or recreate the removed checkpoint.
        pad.fileIntoNote(target)
        #expect(pad.saveIfNeeded() == nil)
        #expect(pad.filingCompletionMessage == notice)
        #expect(try Data(contentsOf: targetFile) == targetBytes)
        #expect(try Data(contentsOf: sourceFile) == sourceBytes)
        #expect(files.trashedURLs == [sourceFile])
        await journal.flush()
        let restarted = DraftJournal(directoryURL: journal.directoryURL)
        await restarted.scan()
        #expect(restarted.recoveredDrafts.isEmpty)

        let nextWords = "  A different Cafe\u{0301} thought.\r\n"
        pad.text = nextWords
        let nextDraft = try await recoveredFilingDraft(in: journal)
        #expect(nextDraft.id != priorDraft.id)
        #expect(nextDraft.originalFilePath == nil)
        #expect(nextDraft.noteID == nil)
        #expect(nextDraft.baseline == "")
        #expect(nextDraft.baselineRevision == nil)
        #expect(Data(nextDraft.text.utf8) == Data(nextWords.utf8))
        #expect(pad.filingCompletionMessage == notice)
        let nextSaved = try #require(pad.saveIfNeeded())
        #expect(nextSaved.id != saved.id)
        #expect(nextSaved.id != target.id)
        #expect(nextSaved.fileURL != sourceFile)
        #expect(nextSaved.fileURL != targetFile)
        #expect(Data(pad.text.utf8) == Data(nextWords.utf8))
        #expect(pad.filingCompletionMessage == notice, "An ordinary save cannot hide the earlier partial-success outcome.")
        #expect(try Data(contentsOf: sourceFile) == sourceBytes)
        #expect(try Data(contentsOf: targetFile) == targetBytes)
        #expect(files.trashedURLs == [sourceFile])

        pad.reviewFilingTargetsInLibrary()
        #expect(reviews == 1)
        #expect(stoppedCaptureSessions == 1)
        #expect(pad.filingCompletionMessage == notice)
        pad.dismissFilingCompletion()
        #expect(pad.filingCompletionMessage == nil)
        #expect(Data(pad.text.utf8) == Data(nextWords.utf8))
        #expect(try Data(contentsOf: sourceFile) == sourceBytes)
        #expect(try Data(contentsOf: targetFile) == targetBytes)
    }

    // MARK: Model output that reaches the note

    @Test
    func anActionListTheNoteCannotAccountForLeavesTheNoteAlone() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let pad = QuickNoteController(store: store)

        pad.text = "Remember to send Priya the revised pricing mockups."
        pad.applyForTesting(
            """
            - Migrate the billing service to Stripe
            - Cancel the Braintree contract
            """,
            for: .actionItems
        )

        #expect(
            pad.text == "Remember to send Priya the revised pricing mockups."
        )
        #expect(pad.message == QuickNoteController.keptYourOwnWordsNotice)
        #expect(pad.messageIsAdvisory)
    }

    @Test
    func actionsDrawnFromTheNoteAreAppendedUnderTheirHeading() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let pad = QuickNoteController(store: store)

        pad.text = "Remember to send Priya the revised pricing mockups."
        pad.applyForTesting(
            "- Send Priya the revised pricing mockups",
            for: .actionItems
        )

        #expect(pad.text.contains("## Find actions"))
        #expect(pad.text.contains("- Send Priya the revised pricing mockups"))
        #expect(pad.message == nil)
    }
}
