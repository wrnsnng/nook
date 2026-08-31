import Foundation
import Testing
@testable import Nook

/// Exercises the actual save/cleanup workflow. Every note and journal is
/// synthetic, the summarizer is fixed, and Trash can only retain fixture files.
@MainActor
struct NoteMergeWorkflowTests {
    @Test(arguments: [false, true])
    func eitherPickerOrderingKeepsTheEarlierFileAndRetainsOnlyTheAbsorbedSource(incomingIsEarlier: Bool) async throws {
        let fixture = try MergeWorkflowFixture()
        defer { fixture.cleanup() }
        let originals = try fixture.sourceBytes()
        let incoming = incomingIsEarlier ? fixture.earlier : fixture.later
        let target = incomingIsEarlier ? fixture.later : fixture.earlier
        let workflow = NoteMergeWorkflow(combine: fixtureCombine)

        let completion = try await fixture.merge(workflow, incoming: incoming, target: target)

        #expect(completion.saved.libraryIdentity == fixture.earlier.libraryIdentity)
        #expect(completion.absorbed.libraryIdentity == fixture.later.libraryIdentity)
        #expect(!completion.hasPartialSuccess)
        #expect(!workflow.isRunning)
        #expect(fixture.manager.trashedURLs == [try #require(fixture.later.fileURL)])
        #expect(try Data(contentsOf: #require(fixture.manager.retainedURLs.first)) == originals[fixture.later.id])
        #expect(!FileManager.default.fileExists(atPath: try #require(fixture.later.fileURL).path))
        #expect(fixture.store.notes.map(\.id) == [fixture.earlier.id])
        try fixture.expectBothSittingsOnce()
    }

    @Test
    func dirtyMarkdownRefusesTheMergeAndRetainsExactDraftAndRecoveryBytes() async throws {
        let fixture = try MergeWorkflowFixture()
        defer { fixture.cleanup() }
        let original = try fixture.sourceBytes()
        fixture.markdown.prepare(for: fixture.earlier, store: fixture.store)
        let exact = fixture.markdown.rawMarkdown + "\n  Cafe\u{301} unfinished source.\t\n"
        fixture.markdown.rawMarkdown = exact
        let calls = MergeWorkflowCalls()
        let workflow = NoteMergeWorkflow { input in
            await calls.didCombine()
            return try await fixtureCombine(input)
        }

        await #expect(throws: NoteMergeError.self) { try await fixture.merge(workflow) }

        #expect(await calls.combineCount == 0)
        #expect(fixture.markdown.hasChanges)
        #expect(fixture.markdown.rawMarkdown.utf8.elementsEqual(exact.utf8))
        #expect(try fixture.sourceBytes() == original)
        #expect(fixture.manager.trashedURLs.isEmpty)
        let checkpoint = try #require(await fixture.recovered().first { $0.kind == .markdown })
        #expect(checkpoint.text.utf8.elementsEqual(exact.utf8))
        #expect(checkpoint.originalFilePath == fixture.earlier.fileURL?
            .standardizedFileURL.resolvingSymlinksInPath().path)
    }

    @Test(arguments: [false, true])
    func failedPersonalOrParkedSavesKeepEveryDraftAndPreventTheMerge(alsoParkEarlierDraft: Bool) async throws {
        let fixture = try MergeWorkflowFixture()
        defer { fixture.cleanup() }
        let original = try fixture.sourceBytes()
        fixture.personal.prepare(for: fixture.earlier, store: fixture.store)
        let first = "  Cafe\u{301} personal words.\n"
        fixture.personal.text = first
        fixture.writeBoundary.action = { _ in throw CocoaError(.fileWriteNoPermission) }
        let second = "Second unsaved draft.\t\n"
        if alsoParkEarlierDraft {
            fixture.personal.prepare(for: fixture.later, store: fixture.store)
            fixture.personal.text = second
        }
        let calls = MergeWorkflowCalls()
        let workflow = NoteMergeWorkflow { input in
            await calls.didCombine()
            return try await fixtureCombine(input)
        }

        await #expect(throws: NoteMergeError.self) { try await fixture.merge(workflow) }

        #expect(await calls.combineCount == 0)
        #expect(try fixture.sourceBytes() == original)
        #expect(fixture.manager.trashedURLs.isEmpty)
        #expect(fixture.personal.hasExactChanges)
        #expect(fixture.personal.statusMessage != nil)
        let recovered = await fixture.recovered()
        let firstCheckpoint = try #require(recovered.first { $0.noteID == fixture.earlier.id })
        #expect(firstCheckpoint.text.utf8.elementsEqual(first.utf8))
        if alsoParkEarlierDraft {
            #expect(fixture.personal.parkedDrafts.count == 1)
            #expect(fixture.personal.parkedDrafts.first?.text.utf8.elementsEqual(first.utf8) == true)
            #expect(fixture.personal.text.utf8.elementsEqual(second.utf8))
            let secondCheckpoint = try #require(recovered.first { $0.noteID == fixture.later.id })
            #expect(secondCheckpoint.text.utf8.elementsEqual(second.utf8))
        } else {
            #expect(fixture.personal.text.utf8.elementsEqual(first.utf8))
        }
    }

    @Test(arguments: [false, true])
    func freshPersonalWordsAreSavedBeforeSnapshotsAndIncludedInTheMerge(editEarlier: Bool) async throws {
        let fixture = try MergeWorkflowFixture()
        defer { fixture.cleanup() }
        let edited = editEarlier ? fixture.earlier : fixture.later
        let exact = "Fresh Cafe\u{301} preparation.\n\n  Keep this indentation."
        fixture.personal.prepare(for: edited, store: fixture.store)
        fixture.personal.text = exact
        let workflow = NoteMergeWorkflow { input in
            let captured = input.incoming.id == edited.id ? input.incoming : input.target
            #expect(captured.personalNotes.utf8.elementsEqual(exact.utf8))
            #expect(captured.fileRevision != edited.fileRevision)
            return try await fixtureCombine(input)
        }

        let completion = try await fixture.merge(workflow)

        #expect(!completion.hasPartialSuccess)
        #expect(!fixture.personal.hasExactChanges)
        let saved = try fixture.persistedEarlier()
        #expect(saved.personalNotes.contains(exact))
        #expect(await fixture.recovered().isEmpty)
        try fixture.expectBothSittingsOnce()
    }

    @Test
    func aGenerationCapturedBeforeSchedulingCannotAuthorizeAFolderRoundTrip() async throws {
        let fixture = try MergeWorkflowFixture()
        defer { fixture.cleanup() }
        let original = try fixture.sourceBytes()
        let expectedGeneration = fixture.store.storageGeneration
        fixture.personal.prepare(for: fixture.earlier, store: fixture.store)
        fixture.personal.text = MergeWorkflowFixture.pendingWords
        fixture.store.storageURL = fixture.otherLibrary
        fixture.store.storageURL = fixture.notesDirectory
        let calls = MergeWorkflowCalls()
        let workflow = NoteMergeWorkflow { input in
            await calls.didCombine()
            return try await fixtureCombine(input)
        }

        await #expect(throws: NoteMergeError.self) {
            try await workflow.merge(
                fixture.later, into: fixture.earlier,
                store: fixture.store, markdown: fixture.markdown, personal: fixture.personal,
                expectedGeneration: expectedGeneration
            )
        }

        #expect(await calls.combineCount == 0)
        #expect(try fixture.sourceBytes() == original)
        #expect(fixture.manager.trashedURLs.isEmpty)
        #expect(fixture.personal.hasExactChanges)
        #expect(fixture.personal.text.utf8.elementsEqual(MergeWorkflowFixture.pendingWords.utf8))
    }

    @Test
    func aCleanSurvivingMarkdownEditorAdvancesAndItsNextEditCanSaveBothSessions() async throws {
        let fixture = try MergeWorkflowFixture()
        defer { fixture.cleanup() }
        fixture.markdown.prepare(for: fixture.earlier, store: fixture.store)
        let previousSource = fixture.markdown.rawMarkdown
        let workflow = NoteMergeWorkflow(combine: fixtureCombine)

        let completion = try await fixture.merge(workflow)

        let survivor = try #require(completion.saved.fileURL)
        let mergedBytes = try Data(contentsOf: survivor)
        #expect(!fixture.markdown.hasChanges)
        #expect(fixture.markdown.libraryIdentity == completion.saved.libraryIdentity)
        #expect(Data(fixture.markdown.rawMarkdown.utf8) == mergedBytes)
        #expect(Data(fixture.markdown.originalMarkdown.utf8) == mergedBytes)
        #expect(fixture.markdown.rawMarkdown != previousSource)
        let exactEdit = fixture.markdown.rawMarkdown + "\n\nMy follow-up after merging.\n"
        fixture.markdown.rawMarkdown = exactEdit
        try fixture.markdown.save(note: completion.saved, store: fixture.store)

        #expect(!fixture.markdown.hasChanges)
        #expect(try Data(contentsOf: survivor) == Data(exactEdit.utf8))
        #expect(fixture.markdown.statusMessage == "Saved")
        try fixture.expectBothSittingsOnce()
    }

    @Test(arguments: MergeWorkflowInterference.allCases)
    func editsOrLibraryRoundTripsDuringGenerationKeepBothSources(interference: MergeWorkflowInterference) async throws {
        let fixture = try MergeWorkflowFixture()
        defer { fixture.cleanup() }
        let gate = MergeWorkflowGate()
        let workflow = NoteMergeWorkflow { input in
            await gate.hold()
            return try await fixtureCombine(input)
        }
        let work = Task { try await fixture.merge(workflow) }
        await gate.waitUntilHeld()
        try fixture.interfere(interference)
        let expected = try fixture.sourceBytes()
        await gate.release()

        await #expect(throws: NoteMergeError.self) { try await work.value }

        #expect(!workflow.isRunning)
        #expect(try fixture.sourceBytes() == expected)
        #expect(fixture.manager.trashedURLs.isEmpty)
        #expect(fixture.store.notes.count == 2)
        #expect(!FileManager.default.fileExists(atPath: fixture.otherLibrary.appendingPathComponent(".recordings").path))
        await fixture.expectPendingWordsRetained(for: interference)
    }

    @Test
    func anAbsorbedFileEditAtTheWriteBoundaryPreventsEitherOriginalFromBeingReplaced() async throws {
        let fixture = try MergeWorkflowFixture()
        defer { fixture.cleanup() }
        let originals = try fixture.sourceBytes()
        var changed = fixture.later
        changed.summary = "An external edit arrived while the merged file was staged."
        let changedBytes = Data(MarkdownCodec.encode(changed).utf8)
        let absorbedURL = try #require(fixture.later.fileURL)
        let survivorURL = try #require(fixture.earlier.fileURL)
        fixture.writeBoundary.action = { destination in
            #expect(destination.standardizedFileURL == survivorURL.standardizedFileURL)
            try changedBytes.write(to: absorbedURL, options: .atomic)
        }
        let workflow = NoteMergeWorkflow(combine: fixtureCombine)

        await #expect(throws: NoteMergeError.self) { try await fixture.merge(workflow) }

        #expect(try Data(contentsOf: survivorURL) == originals[fixture.earlier.id])
        #expect(try Data(contentsOf: absorbedURL) == changedBytes)
        #expect(fixture.manager.trashedURLs.isEmpty)
        #expect(fixture.store.notes.count == 2)
    }

    @Test(arguments: MergeWorkflowInterference.allCases)
    func changesAfterTextWasSavedReturnReviewablePartialSuccessAndKeepTheAbsorbedFile(interference: MergeWorkflowInterference) async throws {
        let fixture = try MergeWorkflowFixture()
        defer { fixture.cleanup() }
        let gate = MergeWorkflowGate()
        let calls = MergeWorkflowCalls()
        let workflow = NoteMergeWorkflow { input in
            await calls.didCombine()
            let result = try await fixtureCombine(input)
            return NoteCombiner.Result(
                merged: result.merged, absorbed: result.absorbed,
                audioOutcome: .none,
                commitAudio: {
                    await gate.hold()
                    try await input.validateAudioCommit()
                    await calls.didCommitAudio()
                }
            )
        }
        let work = Task { try await fixture.merge(workflow) }
        await gate.waitUntilHeld()
        try fixture.expectBothSittingsOnce()
        try fixture.interfere(interference)
        let expected = try fixture.sourceBytes()
        await gate.release()
        let completion = try await work.value

        #expect(completion.hasPartialSuccess)
        #expect(completion.retainedCopy)
        #expect(completion.problem != nil)
        #expect(completion.notice.contains("Review both notes in the original folder; do not merge these notes again."))
        #expect(try fixture.sourceBytes() == expected)
        #expect(fixture.manager.trashedURLs.isEmpty)
        #expect(await calls.audioCommitCount == 0)
        await fixture.expectPendingWordsRetained(for: interference)
        // A partial result is already an append, even after a reversed callback.
        await #expect(throws: NoteMergeError.self) {
            try await fixture.merge(workflow, incoming: fixture.earlier, target: fixture.later)
        }
        #expect(await calls.combineCount == 1)
        #expect(try fixture.sourceBytes() == expected)
    }

    @Test
    func aFailedTrashKeepsTheCopyAndRepeatedOrReversedCallbacksCannotAppendAgain() async throws {
        let fixture = try MergeWorkflowFixture()
        defer { fixture.cleanup() }
        fixture.manager.rejectsTrash = true
        let originalAbsorbed = try Data(contentsOf: #require(fixture.later.fileURL))
        let calls = MergeWorkflowCalls()
        let workflow = NoteMergeWorkflow { input in
            await calls.didCombine()
            return try await fixtureCombine(input)
        }

        let completion = try await fixture.merge(workflow)
        let completedBytes = try fixture.sourceBytes()
        #expect(completion.retainedCopy)
        #expect(completion.hasPartialSuccess)
        #expect(completion.problem != nil)
        #expect(try Data(contentsOf: #require(fixture.later.fileURL)) == originalAbsorbed)
        try fixture.expectBothSittingsOnce()
        for reversed in [false, true] {
            await #expect(throws: NoteMergeError.self) {
                try await fixture.merge(
                    workflow,
                    incoming: reversed ? fixture.earlier : fixture.later,
                    target: reversed ? fixture.later : fixture.earlier
                )
            }
        }
        #expect(await calls.combineCount == 1)
        #expect(fixture.manager.trashedURLs.count == 1)
        #expect(fixture.manager.retainedURLs.isEmpty)
        #expect(try fixture.sourceBytes() == completedBytes)
        #expect(fixture.store.notes.count == 2)
        #expect(!workflow.isRunning)
    }

    @Test
    func failedReadbackAfterTheRenameRequiresReviewAndCannotBeRetriedAsAnotherAppend() async throws {
        let fixture = try MergeWorkflowFixture()
        defer { fixture.cleanup() }
        let originals = try fixture.sourceBytes()
        let survivorURL = try #require(fixture.earlier.fileURL)
        let readback = MergeReadbackProbe()
        fixture.writeBoundary.read = { url in
            let committedBytes = try Data(contentsOf: url)
            guard url.standardizedFileURL == survivorURL.standardizedFileURL else {
                return committedBytes
            }
            // This hook runs after rename/fsync, so the failure represents a
            // committed write whose verification could not read its result.
            readback.committedBytes = committedBytes
            readback.failures += 1
            throw CocoaError(.fileReadNoPermission)
        }
        let calls = MergeWorkflowCalls()
        let workflow = NoteMergeWorkflow { input in
            await calls.didCombine()
            return try await fixtureCombine(input)
        }

        do {
            _ = try await fixture.merge(workflow)
            Issue.record("An unverifiable committed merge must require review.")
        } catch let error as NoteMergeError {
            guard case .saveUncertain = error else {
                Issue.record("Expected the post-commit review warning, received \(error.localizedDescription)")
                return
            }
        }

        #expect(readback.failures == 1)
        #expect(readback.committedBytes != originals[fixture.earlier.id])
        #expect(try Data(contentsOf: survivorURL) == readback.committedBytes)
        try fixture.expectBothSittingsOnce()
        #expect(try Data(contentsOf: #require(fixture.later.fileURL)) == originals[fixture.later.id])
        #expect(fixture.manager.trashedURLs.isEmpty)
        let committed = try fixture.sourceBytes()
        for reversed in [false, true] {
            await #expect(throws: NoteMergeError.self) {
                try await fixture.merge(
                    workflow,
                    incoming: reversed ? fixture.earlier : fixture.later,
                    target: reversed ? fixture.later : fixture.earlier
                )
            }
        }
        #expect(await calls.combineCount == 1)
        #expect(readback.failures == 1)
        #expect(try fixture.sourceBytes() == committed)
        #expect(fixture.manager.trashedURLs.isEmpty)
    }

    @Test
    func anotherCallbackWhileGenerationIsRunningCannotStartASecondMerge() async throws {
        let fixture = try MergeWorkflowFixture()
        defer { fixture.cleanup() }
        let gate = MergeWorkflowGate()
        let calls = MergeWorkflowCalls()
        let workflow = NoteMergeWorkflow { input in
            await calls.didCombine()
            await gate.hold()
            return try await fixtureCombine(input)
        }
        let work = Task { try await fixture.merge(workflow) }
        await gate.waitUntilHeld()
        #expect(workflow.isRunning)
        await #expect(throws: NoteMergeError.self) {
            try await fixture.merge(workflow, incoming: fixture.earlier, target: fixture.later)
        }
        await gate.release()
        let completed = try await work.value

        #expect(!completed.hasPartialSuccess)
        #expect(await calls.combineCount == 1)
        #expect(fixture.manager.trashedURLs.count == 1)
        try fixture.expectBothSittingsOnce()
    }
}

private struct MergeWorkflowSummarizer: NoteSummarizing {
    func summarize(transcript: [TranscriptSegment], fallbackTitle: String) async -> MeetingInsights {
        MeetingInsights(
            title: fallbackTitle, summary: "The synthetic sessions were combined.",
            keyPoints: [], decisions: [], actionItems: []
        )
    }
}

private func fixtureCombine(_ input: NoteMergeWorkflow.Input) async throws -> NoteCombiner.Result {
    try await NoteCombiner.merge(
        input.incoming, into: input.target,
        recordingsDirectory: input.recordingsDirectory,
        summarizer: MergeWorkflowSummarizer(),
        unusableAudioDestination: .renameBeside,
        validatingBeforeAudioCommit: input.validateAudioCommit
    )
}

enum MergeWorkflowInterference: CaseIterable, Equatable, Sendable {
    case earlierFile, laterFile, markdownDraft, personalDraft, libraryRoundTrip
}

private actor MergeWorkflowCalls {
    private(set) var combineCount = 0
    private(set) var audioCommitCount = 0
    func didCombine() { combineCount += 1 }
    func didCommitAudio() { audioCommitCount += 1 }
}

private actor MergeWorkflowGate {
    private var held: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    func hold() async {
        await withCheckedContinuation { continuation in
            held = continuation
            waiting?.resume()
            waiting = nil
        }
    }
    func waitUntilHeld() async {
        guard held == nil else { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func release() {
        held?.resume()
        held = nil
    }
}

@MainActor
private final class MergeWriteBoundary {
    var action: (URL) throws -> Void = { _ in }
    var read: (URL) throws -> Data = { try Data(contentsOf: $0) }
}

@MainActor
private final class MergeReadbackProbe {
    var committedBytes: Data?
    var failures = 0
}

@MainActor
private final class MergeWorkflowFixture {
    let root: URL
    let notesDirectory: URL
    let otherLibrary: URL
    let manager: MergeWorkflowFileManager
    let writeBoundary = MergeWriteBoundary()
    let store: MarkdownStore
    let journal: DraftJournal
    let markdown: MarkdownDraftController
    let personal: PersonalNotesDraftController
    let earlier: MeetingNote
    let later: MeetingNote
    static let pendingWords = "  Cafe\u{301} unfinished words.\t\n"

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NookMergeWorkflow-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        notesDirectory = root.appendingPathComponent("Notes", isDirectory: true)
        otherLibrary = root.appendingPathComponent("OtherLibrary", isDirectory: true)
        try FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherLibrary, withIntermediateDirectories: true)
        manager = MergeWorkflowFileManager(root: root)
        let boundary = writeBoundary
        let fixtureDirectories = [notesDirectory, otherLibrary].map(\.standardizedFileURL)
        store = MarkdownStore(
            fileManager: manager,
            noteLoader: { directory, cache in
                // A source conflict legitimately reloads the library. Read
                // those synthetic files instead of publishing an empty stub;
                // the initializer's configured real folder remains excluded.
                guard fixtureDirectories.contains(directory.standardizedFileURL) else {
                    return .success((notes: [], issues: []))
                }
                return MarkdownStore.loadNotes(in: directory, cache: cache)
            },
            readCommittedBytes: { try boundary.read($0) },
            beforeWriteCommit: { try boundary.action($0) }
        )
        store.storageURL = notesDirectory
        journal = DraftJournal(directoryURL: root.appendingPathComponent("Drafts", isDirectory: true))
        markdown = MarkdownDraftController(recovery: journal)
        personal = PersonalNotesDraftController(recovery: journal)
        earlier = try store.save(MeetingNote(
            title: "Synthetic first session", startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_060), sourceApp: "Manual",
            summary: "First session summary.", personalNotes: "First personal note.",
            transcript: [TranscriptSegment(startTime: 0, duration: 3, text: "First synthetic sitting.")]
        ))
        later = try store.save(MeetingNote(
            title: "Synthetic later session", startedAt: Date(timeIntervalSince1970: 1_700_001_000),
            endedAt: Date(timeIntervalSince1970: 1_700_001_060), sourceApp: "Manual",
            summary: "Later session summary.", personalNotes: "Later personal note.",
            transcript: [TranscriptSegment(startTime: 0, duration: 3, text: "Second synthetic sitting.")]
        ))
    }

    func cleanup() {
        journal.flushSynchronously()
        try? FileManager.default.removeItem(at: root)
    }

    func merge(
        _ workflow: NoteMergeWorkflow, incoming: MeetingNote? = nil, target: MeetingNote? = nil
    ) async throws -> NoteMergeWorkflow.Completion {
        try await workflow.merge(
            incoming ?? later, into: target ?? earlier,
            store: store, markdown: markdown, personal: personal
        )
    }

    func sourceBytes() throws -> [UUID: Data] {
        try Dictionary(uniqueKeysWithValues: [earlier, later].map {
            ($0.id, try Data(contentsOf: #require($0.fileURL)))
        })
    }

    func persistedEarlier() throws -> MeetingNote {
        let file = try #require(earlier.fileURL)
        let markdown = try String(contentsOf: file, encoding: .utf8)
        return try #require(MarkdownCodec.decode(markdown, fileURL: file))
    }

    func expectBothSittingsOnce() throws {
        let text = try persistedEarlier().transcript.map(\.text).joined(separator: " ")
        #expect(text.components(separatedBy: "First synthetic sitting.").count == 2)
        #expect(text.components(separatedBy: "Second synthetic sitting.").count == 2)
    }

    func recovered() async -> [DraftCheckpoint] {
        await journal.flush()
        let restart = DraftJournal(directoryURL: journal.directoryURL)
        await restart.scan()
        return restart.recoveredDrafts
    }

    func interfere(_ interference: MergeWorkflowInterference) throws {
        switch interference {
        case .earlierFile, .laterFile:
            let owner = interference == .earlierFile ? earlier : later
            let file = try #require(owner.fileURL)
            let bytes = try Data(contentsOf: file) + Data("\n\nExternal source edit.\n".utf8)
            try bytes.write(to: file, options: .atomic)
        case .markdownDraft:
            let current = try #require(store.note(matching: earlier.libraryIdentity))
            markdown.prepare(for: current, store: store)
            markdown.rawMarkdown += Self.pendingWords
        case .personalDraft:
            let current = try #require(store.note(matching: later.libraryIdentity))
            personal.prepare(for: current, store: store)
            personal.text = Self.pendingWords
        case .libraryRoundTrip:
            let identities = store.notes.map(\.libraryIdentity)
            store.storageURL = otherLibrary
            store.storageURL = notesDirectory
            #expect(store.notes.map(\.libraryIdentity) == identities)
        }
    }

    func expectPendingWordsRetained(for interference: MergeWorkflowInterference) async {
        switch interference {
        case .markdownDraft:
            #expect(markdown.hasChanges)
            #expect(markdown.rawMarkdown.hasSuffix(Self.pendingWords))
            let checkpoints = await recovered()
            #expect(checkpoints.contains { $0.kind == .markdown && $0.text.utf8.elementsEqual(markdown.rawMarkdown.utf8) })
        case .personalDraft:
            #expect(personal.hasExactChanges)
            #expect(personal.text.utf8.elementsEqual(Self.pendingWords.utf8))
            let checkpoints = await recovered()
            #expect(checkpoints.contains { $0.kind == .personalNotes && $0.text.utf8.elementsEqual(Self.pendingWords.utf8) })
        default:
            break
        }
    }
}

/// Never forwards to the real Trash, even if a regression reaches cleanup.
/// Refusing directory creation outside the fixture also isolates store init.
private final class MergeWorkflowFileManager: FileManager {
    let root: URL
    var rejectsTrash = false
    private(set) var trashedURLs: [URL] = []
    private(set) var retainedURLs: [URL] = []

    init(root: URL) {
        self.root = root
        super.init()
    }

    override func createDirectory(
        at url: URL, withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        guard owns(url) else { throw CocoaError(.fileWriteNoPermission) }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }

    override func trashItem(
        at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?
    ) throws {
        guard owns(url) else { throw CocoaError(.fileWriteNoPermission) }
        trashedURLs.append(url)
        if rejectsTrash { throw CocoaError(.fileWriteNoPermission) }
        let retained = root.appendingPathComponent("Retained", isDirectory: true)
        try createDirectory(at: retained, withIntermediateDirectories: true)
        let destination = retained.appendingPathComponent(UUID().uuidString + ".md")
        try moveItem(at: url, to: destination)
        retainedURLs.append(destination)
        resultingItemURL?.pointee = destination as NSURL
    }

    private func owns(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }
}
