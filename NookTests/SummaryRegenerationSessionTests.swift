import Foundation
import Testing
@testable import Nook

@MainActor
struct SummaryRegenerationSessionTests {
    private let folder = URL(fileURLWithPath: "/synthetic/LibraryA", isDirectory: true)

    private func note() -> MeetingNote {
        var note = MeetingNote(
            title: "Caf\u{00e9} review",
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            endedAt: Date(timeIntervalSince1970: 1_780_000_060),
            sourceApp: "Synthetic", summary: "Original summary.",
            transcript: [TranscriptSegment(
                startTime: 0, duration: 10, text: "The Caf\u{00e9} review is on Friday.", source: .system
            )],
            fileURL: folder.appendingPathComponent("review.md")
        )
        note.fileRevision = Data([1])
        return note
    }

    private func generated(from note: MeetingNote) -> SummaryRegenerator.Outcome {
        var updated = note
        updated.title = "Generated review title"
        updated.summary = "A generated summary of the synthetic conversation."
        return .regenerated(updated)
    }

    @Test
    func pendingSummarySurvivesMarkdownRelaunchWithoutStartingAModel() throws {
        var original = note()
        original.summaryPending = .initial
        let markdown = MarkdownCodec.encode(original)
        #expect(markdown.contains("summary_status: pending"))
        let reopened = try #require(MarkdownCodec.decode(markdown, fileURL: original.fileURL))
        #expect(reopened.summaryPending == .initial)
        #expect(reopened.transcript.map(\.text) == original.transcript.map(\.text))
        let session = SummaryRegenerationSession()
        #expect(!session.isRunning)
        #expect(session.statusMessage(summaryPending: reopened.summaryPending != nil)?.contains("Retry") == true)
        original.summaryPending = nil
        #expect(!MarkdownCodec.encode(original).contains("summary_status:"))
        #expect(MarkdownCodec.decode(MarkdownCodec.encode(original))?.summaryPending == nil)
    }

    @Test
    func aSuccessfulWriteUpCannotEraseThePartialRecordingWarning() {
        var original = note()
        original.summary = MeetingCoordinator.liveCaptionNoteMarker + "\n\nOld transcript highlights."
        let updated = SummaryRegenerator.preservingRecoveryNotice("A new write-up.", from: original)
        #expect(updated.hasPrefix(MeetingCoordinator.liveCaptionNoteMarker))
        #expect(updated.hasSuffix("A new write-up."))
        #expect(!updated.contains("Old transcript highlights."))
        #expect(SummaryRegenerator.preservingRecoveryNotice("A new write-up.", from: note()) == "A new write-up.")
    }

    @Test(arguments: [SummaryRegenerationSession.Purpose.initial, .appended])
    func backgroundEnrichmentKeepsConcurrentEditsAndMarksOnlySuccessFinished(
        purpose: SummaryRegenerationSession.Purpose
    ) async throws {
        var original = note()
        original.summaryPending = .initial
        original.actionItems = ["Send the report"]
        let library = RegenerationTestLibrary(folder: folder, notes: [original])
        let runner = ControlledRegenerationRunner()
        defer { runner.finishAll() }
        let session = SummaryRegenerationSession(runner: runner.run)
        let task = try #require(session.start(
            note: original, purpose: purpose, library: library.read, commit: library.commit
        ))
        await runner.waitForRequests(1)
        library.notes[0].title = "User title during processing"
        library.notes[0].completedActionItems = ["Send the report"]
        library.notes[0].extraSections = [.init(heading: "## Private context", body: "Synthetic words", anchor: nil)]
        var output = original
        output.title = "Model title"
        output.summary = "A grounded write-up"
        output.actionItems = ["Review the plan"]
        runner.finish(0, with: .regenerated(output))
        await task.value
        let saved = try #require(library.commits.first)
        #expect(saved.summaryPending == nil)
        #expect(saved.title == "User title during processing")
        #expect(saved.summary == "A grounded write-up")
        #expect(saved.actionItems == ["Send the report"])
        #expect(saved.completedActionItems == ["Send the report"])
        #expect(saved.transcript == original.transcript)
        #expect(saved.extraSections == library.notes[0].extraSections)
    }

    @Test
    func appendedEnrichmentPreservesExistingActionsAlongsideNewOnes() async throws {
        var original = note()
        original.summaryPending = .appended
        original.actionItems = ["Existing follow-up"]
        // The retry happens after a file round-trip, with no remembered job.
        original = try #require(MarkdownCodec.decode(MarkdownCodec.encode(original), fileURL: original.fileURL))
        #expect(original.summaryPending == .appended)
        let library = RegenerationTestLibrary(folder: folder, notes: [original])
        var output = original
        output.actionItems = ["New follow-up"]
        let generated = output
        let session = SummaryRegenerationSession(runner: { _, _ in .regenerated(generated) })
        let task = try #require(session.start(
            note: original, purpose: .forRetry(of: original), library: library.read, commit: library.commit
        ))
        await task.value
        #expect(library.notes[0].actionItems == ["Existing follow-up", "New follow-up"])
        #expect(library.notes[0].summaryPending == nil)
    }

    @Test(arguments: [SummaryService.FailureReason.modelBusy, .timedOut, .ungrounded])
    func aFailedBackgroundSummaryRetainsTheExactSavedNoteAndOffersRetry(
        reason: SummaryService.FailureReason
    ) async throws {
        var original = note()
        original.summaryPending = .initial
        let library = RegenerationTestLibrary(folder: folder, notes: [original])
        let session = SummaryRegenerationSession(runner: { _, _ in .retained(reason: reason) })
        let task = try #require(session.start(
            note: original, purpose: .initial, library: library.read, commit: library.commit
        ))
        await task.value
        #expect(library.commits.isEmpty)
        #expect(library.notes == [original])
        #expect(!session.isRunning)
        #expect(session.statusMessage(summaryPending: true) == RegenerationCopy.retainedMessage(for: reason))
    }

    @Test
    func aDeadlineReleasesTheSavedNoteEvenWhenTheModelNeverCooperates() async throws {
        var original = note()
        original.summaryPending = .initial
        let library = RegenerationTestLibrary(folder: folder, notes: [original])
        let runner = ControlledRegenerationRunner()
        defer { runner.finishAll() }
        let session = SummaryRegenerationSession(runner: runner.run, timeout: 0.05)
        let task = try #require(session.start(
            note: original, purpose: .initial, library: library.read, commit: library.commit
        ))
        await runner.waitForRequests(1)
        await task.value
        #expect(!session.isRunning)
        guard case .retained(.timedOut) = session.completion?.result else {
            Issue.record("A noncooperative model must time out without losing the note")
            return
        }
        for index in runner.requests.indices {
            await runner.report(.writingUp, request: index)
            runner.finish(index, with: generated(from: original))
        }
        #expect(session.stage == nil)
        #expect(library.commits.isEmpty)
        #expect(library.notes == [original])
    }

    @Test
    func theSameFileSharesItsSessionAndAmbiguousOrRemovedFilesCancelIt() async throws {
        let original = note()
        let library = RegenerationTestLibrary(folder: folder, notes: [original])
        let runner = ControlledRegenerationRunner()
        defer { runner.finishAll() }
        let sessions = NoteSummarySessions(makeSession: { SummaryRegenerationSession(runner: runner.run) })
        let session = sessions.session(for: original)
        let task = try #require(session.start(note: original, library: library.read, commit: library.commit))
        await runner.waitForRequests(1)
        #expect(sessions.session(for: original) === session)
        sessions.reconcile(notes: [original], duplicateIDs: [])
        #expect(session.isRunning)
        sessions.reconcile(notes: [original], duplicateIDs: [original.id])
        #expect(!session.isRunning)
        await task.value
        runner.finish(0, with: generated(from: original))
        #expect(library.commits.isEmpty)
        #expect(sessions.session(for: original) !== session)
    }

    @Test
    func cancellationBeforeTheTaskStartsNeverInvokesTheRunner() async throws {
        let original = note()
        let library = RegenerationTestLibrary(folder: folder, notes: [original])
        let runner = ControlledRegenerationRunner()
        defer { runner.finishAll() }
        let session = SummaryRegenerationSession(runner: runner.run)
        let task = try #require(session.start(note: original, library: library.read, commit: library.commit))
        session.cancel()
        await task.value
        #expect(runner.requests.isEmpty)
        #expect(library.commits.isEmpty)
        #expect(session.stage == nil)
        #expect(session.completion == nil)
    }

    @Test(arguments: [false, true])
    func cancellingTheReturnedWorkReleasesTheRunningStateAndAllowsRetry(afterStart: Bool) async throws {
        let original = note()
        let library = RegenerationTestLibrary(folder: folder, notes: [original])
        let runner = ControlledRegenerationRunner()
        defer { runner.finishAll() }
        let session = SummaryRegenerationSession(runner: runner.run)
        let first = try #require(session.start(note: original, library: library.read, commit: library.commit))
        if afterStart { await runner.waitForRequests(1) }
        first.cancel()
        await first.value
        #expect(!session.isRunning)
        #expect(session.wasCancelled)
        #expect(session.stage == nil)
        #expect(session.completion == nil)
        #expect(library.commits.isEmpty)
        if !afterStart { #expect(runner.requests.isEmpty) }

        let second = try #require(session.start(note: original, library: library.read, commit: library.commit))
        let requestCount = afterStart ? 2 : 1
        await runner.waitForRequests(requestCount)
        if afterStart {
            await runner.report(.writingUp, request: 0)
            runner.finish(0, with: generated(from: original))
            #expect(session.stage == .condensing(pass: 1, part: 0, total: 0))
            #expect(library.commits.isEmpty)
        }
        runner.finish(requestCount - 1, with: generated(from: original))
        await second.value
        #expect(!session.isRunning)
        #expect(!session.wasCancelled)
        #expect(library.commits.count == 1)
    }

    @Test
    func anOldModelCannotStartAgainstARetainedLibraryFromAnotherFolder() {
        let original = note()
        let library = RegenerationTestLibrary(
            folder: URL(fileURLWithPath: "/synthetic/LibraryB", isDirectory: true), notes: [original]
        )
        let runner = ControlledRegenerationRunner()
        let session = SummaryRegenerationSession(runner: runner.run)
        #expect(session.start(note: original, library: library.read, commit: library.commit) == nil)
        #expect(runner.requests.isEmpty)
        #expect(library.commits.isEmpty)
        #expect(!session.isRunning)
        guard case .failed = session.completion?.result else {
            Issue.record("An obsolete model should explain why regeneration did not start.")
            return
        }
    }

    @Test
    func cancelAndRetryIgnoreAnOldRunnersProgressAndResult() async throws {
        let original = note()
        let library = RegenerationTestLibrary(folder: folder, notes: [original])
        let runner = ControlledRegenerationRunner()
        defer { runner.finishAll() }
        let session = SummaryRegenerationSession(runner: runner.run)
        let first = try #require(session.start(note: original, library: library.read, commit: library.commit))
        await runner.waitForRequests(1)
        await runner.report(.writingUp, request: 0)
        #expect(session.stage == .writingUp)

        session.cancel()
        #expect(!session.isRunning)
        #expect(session.stage == nil)
        #expect(session.completion == nil)
        let second = try #require(session.start(note: original, library: library.read, commit: library.commit))
        await runner.waitForRequests(2)
        // Reports are called from this uncanceled test task, so testing only
        // Task.isCancelled in the progress callback cannot pass this case.
        await runner.report(.condensing(pass: 9, part: 9, total: 9), request: 0)
        #expect(session.stage == .condensing(pass: 1, part: 0, total: 0))
        runner.finish(0, with: generated(from: original))
        await first.value
        #expect(library.commits.isEmpty)
        #expect(session.isRunning)
        #expect(session.completion == nil)

        await runner.report(.writingUp, request: 1)
        #expect(session.stage == .writingUp)
        runner.finish(1, with: generated(from: original))
        await second.value
        #expect(library.commits.count == 1)
        #expect(!session.isRunning)
        #expect(session.stage == nil)
        guard case .saved(let saved) = session.completion?.result else {
            Issue.record("The current request should publish its saved note.")
            return
        }
        #expect(saved.libraryIdentity == original.libraryIdentity)
    }

    @Test(arguments: ["folder", "path", "duplicate", "missing", "revisionless", "kind"])
    func aChangedOwnerCannotCommitEvenBeforeTheViewObservesTheChange(change: String) async throws {
        let original = note()
        let library = RegenerationTestLibrary(folder: folder, notes: [original])
        let runner = ControlledRegenerationRunner()
        defer { runner.finishAll() }
        let session = SummaryRegenerationSession(runner: runner.run)
        let task = try #require(session.start(note: original, library: library.read, commit: library.commit))
        await runner.waitForRequests(1)
        switch change {
        case "folder":
            library.folder = URL(fileURLWithPath: "/synthetic/LibraryB", isDirectory: true)
        case "path":
            library.notes[0].fileURL = folder.appendingPathComponent("renamed.md")
        case "duplicate":
            var copy = original
            copy.fileURL = folder.appendingPathComponent("copy.md")
            library.notes.append(copy)
        case "missing": library.notes = []
        case "revisionless": library.notes[0].fileRevision = nil
        default: library.notes[0].kind = .spoken
        }
        // Deliberately do not call cancel or send a progress callback: the
        // completion itself must check the live owner before writing anything.
        runner.finish(0, with: generated(from: original))
        await task.value
        #expect(library.commits.isEmpty)
        #expect(!session.isRunning)
        #expect(session.stage == nil)
        #expect(session.completion == nil)
    }

    @Test(arguments: ["text", "timing", "duration", "source", "guidance", "flag"],
          [SummaryRegenerationSession.Purpose.regeneration, .initial, .appended])
    func changedGenerationInputKeepsTheCurrentNoteAndExplainsWhy(
        change: String, purpose: SummaryRegenerationSession.Purpose
    ) async throws {
        var original = note()
        original.summaryPending = purpose == .initial ? .initial : (purpose == .appended ? .appended : nil)
        let library = RegenerationTestLibrary(folder: folder, notes: [original])
        let runner = ControlledRegenerationRunner()
        defer { runner.finishAll() }
        let session = SummaryRegenerationSession(runner: runner.run)
        let task = try #require(session.start(note: original, purpose: purpose, library: library.read, commit: library.commit))
        await runner.waitForRequests(1)
        let segment = original.transcript[0]
        switch change {
        case "guidance": library.notes[0].personalNotes = "Emphasize the revised date."
        case "flag": library.notes[0].moments = [MeetingMoment(offset: 4)]
        default:
            library.notes[0].transcript = [TranscriptSegment(
                id: segment.id,
                startTime: change == "timing" ? 3 : segment.startTime,
                duration: change == "duration" ? 20 : segment.duration,
                text: change == "text" ? "The Cafe\u{0301} review is on Friday." : segment.text,
                source: change == "source" ? .microphone : segment.source
            )]
        }
        library.notes[0].fileRevision = Data([2])
        let current = library.notes[0]
        runner.finish(0, with: generated(from: original))
        await task.value
        #expect(library.commits.isEmpty)
        #expect(library.notes[0] == current)
        guard case .failed(let message) = session.completion?.result else {
            Issue.record("Input changes should explain why the old result was not saved.")
            return
        }
        #expect(message.contains("guidance changed"))
        #expect(!session.isRunning)
    }

    @Test(arguments: [SummaryRegenerationSession.Purpose.regeneration, .initial, .appended])
    func safeConcurrentEditsKeepTheirExactBytesAndLatestConflictRevision(
        purpose: SummaryRegenerationSession.Purpose
    ) async throws {
        var original = note()
        original.summaryPending = purpose == .initial ? .initial : (purpose == .appended ? .appended : nil)
        let guidance = String(repeating: "a", count: SummaryAttention.maximumMyNotesCharacters)
        original.personalNotes = guidance + " old tail"
        let library = RegenerationTestLibrary(folder: folder, notes: [original])
        let runner = ControlledRegenerationRunner()
        defer { runner.finishAll() }
        let session = SummaryRegenerationSession(runner: runner.run)
        let task = try #require(session.start(note: original, purpose: purpose, library: library.read, commit: library.commit))
        await runner.waitForRequests(1)
        #expect(runner.requests[0].note.fileRevision == original.fileRevision)
        library.notes[0].title = "Cafe\u{0301} review"
        library.notes[0].personalNotes = guidance + " newer tail"
        library.notes[0].fileRevision = Data([7, 8, 9])
        let segment = original.transcript[0]
        library.notes[0].transcript = [TranscriptSegment(
            startTime: segment.startTime, duration: segment.duration,
            text: segment.text, source: segment.source
        )]
        // Regenerated decoder UUIDs and guidance beyond the prompt's cap do
        // not change the input. Keep those newest values while merging.
        let latest = library.notes[0]
        runner.finish(0, with: generated(from: original))
        await task.value
        let committed = try #require(library.commits.first)
        #expect(library.commits.count == 1)
        #expect(committed.fileRevision == latest.fileRevision)
        #expect(Data(committed.title.utf8) == Data(latest.title.utf8))
        #expect(Data(committed.personalNotes.utf8) == Data(latest.personalNotes.utf8))
        #expect(committed.transcript == latest.transcript)
        #expect(committed.summary != original.summary)
        #expect(committed.summaryPending == nil)
    }

    @Test(arguments: [false, true])
    func refusalOrSaveFailureDoesNotClaimThatANoteWasSaved(saveFails: Bool) async throws {
        let original = note()
        let library = RegenerationTestLibrary(folder: folder, notes: [original])
        library.saveFails = saveFails
        let runner = ControlledRegenerationRunner()
        defer { runner.finishAll() }
        let session = SummaryRegenerationSession(runner: runner.run)
        let task = try #require(session.start(note: original, library: library.read, commit: library.commit))
        await runner.waitForRequests(1)
        runner.finish(0, with: saveFails ? generated(from: original) : .retained(reason: .declined))
        await task.value
        #expect(library.notes == [original])
        #expect(library.commits.count == (saveFails ? 1 : 0))
        #expect(!session.isRunning)
        #expect(session.stage == nil)
        if saveFails {
            guard case .failed = session.completion?.result else {
                Issue.record("A failed commit must report failure.")
                return
            }
        } else {
            guard case .retained(.declined) = session.completion?.result else {
                Issue.record("A refused model result must retain the note.")
                return
            }
        }
    }

    @Test
    func releasingTheSessionPreventsAnIgnoringRunnerFromCommitting() async throws {
        let original = note()
        let library = RegenerationTestLibrary(folder: folder, notes: [original])
        let runner = ControlledRegenerationRunner()
        defer { runner.finishAll() }
        var session: SummaryRegenerationSession? = SummaryRegenerationSession(runner: runner.run)
        let sessionWasReleased = { [weak session] in session == nil }
        let task = try #require(session?.start(note: original, library: library.read, commit: library.commit))
        await runner.waitForRequests(1)
        session = nil
        #expect(sessionWasReleased())
        await runner.report(.writingUp, request: 0)
        runner.finish(0, with: generated(from: original))
        await task.value
        #expect(library.commits.isEmpty)
    }

    @Test(arguments: [false, true], [false, true])
    func aRealStoreRetainingOldModelsAfterAFolderLoadFailureCannotSaveIntoEitherFolder(
        reportsProgressFirst: Bool, returnsToOriginalFolder: Bool
    ) async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("NookSummarySession-\(UUID().uuidString)")
        let firstFolder = root.appendingPathComponent("LibraryA", isDirectory: true)
        let secondFolder = root.appendingPathComponent("LibraryB", isDirectory: true)
        try files.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try files.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let guardedFiles = RegenerationFixtureFileManager(root: root)
        let store = MarkdownStore(fileManager: guardedFiles, noteLoader: { directory, cache in
            guard directory.standardizedFileURL == firstFolder.standardizedFileURL else {
                return .failure(CocoaError(.fileReadNoPermission))
            }
            return MarkdownStore.loadNotes(in: directory, cache: cache)
        })
        store.storageURL = firstFolder
        var candidate = note()
        candidate.fileURL = firstFolder.appendingPathComponent("source.md")
        candidate.fileRevision = nil
        let original = try store.save(candidate)
        let originalFile = try #require(original.fileURL)
        let firstBytes = try Data(contentsOf: originalFile)
        let otherFile = secondFolder.appendingPathComponent("unrelated.md")
        let otherBytes = Data("Synthetic independent folder contents.\n".utf8)
        try otherBytes.write(to: otherFile)
        let runner = ControlledRegenerationRunner()
        defer { runner.finishAll() }
        let session = SummaryRegenerationSession(runner: runner.run)
        let commits = RegenerationCommitCounter()
        let startedTask = session.start(
            note: original,
            library: {
                .init(directoryURL: store.storageURL, generation: store.storageGeneration, notes: store.notes)
            },
            commit: { note in
                commits.count += 1
                return try store.save(note)
            }
        )
        let task = try #require(startedTask)
        await runner.waitForRequests(1)
        store.storageURL = secondFolder
        store.reload()
        for _ in 0..<100 where store.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!store.isLoading)
        try #require(store.lastError != nil)
        try #require(store.uniqueNote(id: original.id)?.libraryIdentity == original.libraryIdentity)
        if returnsToOriginalFolder {
            // No view callback or successful reload is needed to invalidate
            // the captured request, even when its old models still match.
            store.storageURL = firstFolder
        }
        if reportsProgressFirst {
            await runner.report(.writingUp, request: 0)
            #expect(session.stage == nil)
        }
        runner.finish(0, with: generated(from: original))
        await task.value
        #expect(commits.count == 0)
        #expect(try Data(contentsOf: originalFile) == firstBytes)
        #expect(try Data(contentsOf: otherFile) == otherBytes)
        #expect(store.storageURL == (returnsToOriginalFolder ? firstFolder : secondFolder))
        #expect(store.lastError != nil)
        #expect(session.completion == nil)
        #expect(!session.isRunning)
    }
}

@MainActor
private final class RegenerationTestLibrary {
    var folder: URL
    var generation = 0
    var notes: [MeetingNote]
    var commits: [MeetingNote] = []
    var saveFails = false

    init(folder: URL, notes: [MeetingNote]) { self.folder = folder; self.notes = notes }
    func read() -> SummaryRegenerationSession.LibrarySnapshot {
        .init(directoryURL: folder, generation: generation, notes: notes)
    }
    func commit(_ note: MeetingNote) throws -> MeetingNote {
        commits.append(note)
        if saveFails { throw CocoaError(.fileWriteNoPermission) }
        notes = [note]
        return note
    }
}

@MainActor
private final class RegenerationCommitCounter { var count = 0 }

/// No provider or model is invoked. Progress can arrive from an unrelated
/// uncanceled task, and completion deliberately ignores cancellation.
@MainActor
private final class ControlledRegenerationRunner {
    struct Request {
        let note: MeetingNote
        let onStage: SummaryStageHandler?
        var continuation: CheckedContinuation<SummaryRegenerator.Outcome, Never>?
    }
    private(set) var requests: [Request] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func run(note: MeetingNote, onStage: SummaryStageHandler?) async -> SummaryRegenerator.Outcome {
        await withCheckedContinuation { continuation in
            requests.append(Request(note: note, onStage: onStage, continuation: continuation))
            let ready = waiters.filter { $0.0 <= requests.count }
            waiters.removeAll { $0.0 <= requests.count }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitForRequests(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func report(_ stage: SummaryStage, request: Int) async { await requests[request].onStage?(stage) }
    func finish(_ index: Int, with outcome: SummaryRegenerator.Outcome) {
        let continuation = requests[index].continuation
        requests[index].continuation = nil
        continuation?.resume(returning: outcome)
    }
    func finishAll() { for index in requests.indices { finish(index, with: .retained(reason: nil)) } }
}

/// Store construction must not create a configured user directory before the
/// test assigns its own path. Only this test's temporary root can be touched.
private final class RegenerationFixtureFileManager: FileManager {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override func createDirectory(
        at url: URL, withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}
