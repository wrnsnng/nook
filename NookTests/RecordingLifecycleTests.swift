import Combine
import Foundation
import Testing
@testable import Nook

@MainActor
struct PermissionRestartLaunchTests {
    @Test(arguments: [false, true])
    func attachmentLaunchWaitsForWindowsAndLibraryInEitherOrder(libraryFirst: Bool) {
        var gate = LaunchPresentationGate()
        let claimedBeforeBothReady = gate.claim(
            windowActionsInstalled: !libraryFirst,
            libraryIsLoading: !libraryFirst,
            pendingStartNeedsLibrary: true
        )
        #expect(!claimedBeforeBothReady)
        #expect(!gate.hasPresented)
        let claimedWhenReady = gate.claim(
            windowActionsInstalled: true,
            libraryIsLoading: false,
            pendingStartNeedsLibrary: true
        )
        #expect(claimedWhenReady)
        #expect(gate.hasPresented)
        // A duplicate window installation or a later reload cannot present
        // the launch experience again, even after the pending keys are gone.
        let claimedAgain = gate.claim(
            windowActionsInstalled: true,
            libraryIsLoading: false,
            pendingStartNeedsLibrary: false
        )
        #expect(!claimedAgain)
    }

    @Test
    func ordinaryWelcomeDoesNotWaitForTheLibrary() {
        var gate = LaunchPresentationGate()
        let claimed = gate.claim(
            windowActionsInstalled: true,
            libraryIsLoading: true,
            pendingStartNeedsLibrary: false
        )
        #expect(claimed)
    }

    @Test
    func anotherReloadKeepsTheAttachmentLaunchPending() {
        var gate = LaunchPresentationGate()
        // A new reload can start after one publication queued the main actor
        // launch callback. The queued callback must not consume the request.
        let claimedDuringReload = gate.claim(
            windowActionsInstalled: true,
            libraryIsLoading: true,
            pendingStartNeedsLibrary: true
        )
        #expect(!claimedDuringReload)
        let claimedAfterReload = gate.claim(
            windowActionsInstalled: true,
            libraryIsLoading: false,
            pendingStartNeedsLibrary: true
        )
        #expect(claimedAfterReload)
    }

    @Test
    func loadingCannotConsumeAnyPersistedAttachmentFields() throws {
        let domain = "nook.permission-restart.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let id = UUID().uuidString
        let path = "/nook-fixtures/Library/original.md"
        defaults.set(true, forKey: "resumeRecordingAfterPermission")
        defaults.set("Synthetic title", forKey: "resumeRecordingAfterPermissionTitle")
        defaults.set("Manual", forKey: "resumeRecordingAfterPermissionSource")
        defaults.set(id, forKey: "resumeRecordingAfterPermissionNoteID")
        defaults.set(path, forKey: "resumeRecordingAfterPermissionNotePath")
        let store = MarkdownStore(noteLoader: { _, _ in .success((notes: [], issues: [])) })
        let coordinator = MeetingCoordinator(store: store, detector: MeetingDetector())

        // This synchronous main actor turn cannot publish the detached load.
        #expect(store.isLoading)
        #expect(MeetingCoordinator.pendingStartNeedsLibrary(defaults: defaults))
        #expect(!coordinator.resumePendingStartAfterPermission(defaults: defaults))
        #expect(defaults.bool(forKey: "resumeRecordingAfterPermission"))
        #expect(defaults.string(forKey: "resumeRecordingAfterPermissionTitle") == "Synthetic title")
        #expect(defaults.string(forKey: "resumeRecordingAfterPermissionSource") == "Manual")
        #expect(defaults.string(forKey: "resumeRecordingAfterPermissionNoteID") == id)
        #expect(defaults.string(forKey: "resumeRecordingAfterPermissionNotePath") == path)
        #expect(coordinator.activeRecordingID == nil)
        #expect(coordinator.phase == .idle)
    }

    @Test
    func aLegacyAttachmentShowsOneRefusalAfterTheLibraryLoads() async throws {
        let domain = "nook.permission-restart.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "resumeRecordingAfterPermission")
        defaults.set("Synthetic title", forKey: "resumeRecordingAfterPermissionTitle")
        defaults.set("Manual", forKey: "resumeRecordingAfterPermissionSource")
        defaults.set(UUID().uuidString, forKey: "resumeRecordingAfterPermissionNoteID")
        let store = MarkdownStore(noteLoader: { _, _ in .success((notes: [], issues: [])) })
        let coordinator = MeetingCoordinator(store: store, detector: MeetingDetector())
        var presentations = 0
        coordinator.onPresentationRequested = { presentations += 1 }
        while store.isLoading { await Task.yield() }

        #expect(coordinator.resumePendingStartAfterPermission(defaults: defaults))
        #expect(presentations == 1)
        #expect(coordinator.activeRecordingID == nil)
        if case .failed(let message) = coordinator.phase {
            #expect(message.contains("Open the original note"))
        } else {
            Issue.record("The legacy attachment must ask for the original note to be selected.")
        }
        #expect(!defaults.bool(forKey: "resumeRecordingAfterPermission"))
        #expect(defaults.string(forKey: "resumeRecordingAfterPermissionTitle") == nil)
        #expect(defaults.string(forKey: "resumeRecordingAfterPermissionSource") == nil)
        #expect(defaults.string(forKey: "resumeRecordingAfterPermissionNoteID") == nil)
        #expect(defaults.string(forKey: "resumeRecordingAfterPermissionNotePath") == nil)
        #expect(!coordinator.resumePendingStartAfterPermission(defaults: defaults))
        #expect(presentations == 1)
    }

    @Test
    func unattachedAndInactiveRequestsDoNotNeedTheLibrary() throws {
        let domain = "nook.permission-restart.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "resumeRecordingAfterPermission")
        #expect(!MeetingCoordinator.pendingStartNeedsLibrary(defaults: defaults))
        defaults.set(UUID().uuidString, forKey: "resumeRecordingAfterPermissionNoteID")
        #expect(MeetingCoordinator.pendingStartNeedsLibrary(defaults: defaults))
        defaults.set(false, forKey: "resumeRecordingAfterPermission")
        #expect(!MeetingCoordinator.pendingStartNeedsLibrary(defaults: defaults))
    }
}

/// A recording retains the file the person chose, even if a copied note with
/// the same frontmatter UUID appears while capture or summarization waits.
@MainActor
struct AttachedRecordingOwnershipTests {
    private let library = URL(fileURLWithPath: "/nook-fixtures/Library", isDirectory: true)

    private func note(id: UUID = UUID(), fileName: String = "original.md") -> MeetingNote {
        MeetingNote(
            id: id,
            title: "Synthetic planning note",
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_060),
            sourceApp: "Manual",
            summary: "The team reviewed a synthetic plan.",
            transcript: [
                TranscriptSegment(
                    startTime: 0,
                    duration: 12,
                    text: "The team reviewed a synthetic plan."
                )
            ],
            fileURL: library.appendingPathComponent(fileName)
        )
    }

    private func target(
        for identity: LibraryNoteIdentity,
        in notes: [MeetingNote],
        libraryURL: URL? = nil
    ) -> MeetingNote? {
        MeetingCoordinator.attachedRecordingTarget(
            expected: identity,
            notes: notes,
            libraryURL: libraryURL ?? library
        )
    }

    @Test
    func theCapturedFileReceivesFreshEditsWithoutChangingOwnership() {
        let original = note()
        var current = original
        current.title = "Title edited while recording"
        current.personalNotes = "Keep this new handwritten thought."
        current.fileRevision = Data([2, 3, 4])

        #expect(target(for: original.libraryIdentity, in: [current]) == current)
    }

    @Test(arguments: [false, true])
    func aCopyAppearingAfterCaptureStartedRefusesEitherArrayOrder(copyFirst: Bool) {
        let original = note()
        let selectedBeforeCapture = original.libraryIdentity
        #expect(target(for: selectedBeforeCapture, in: [original]) == original)
        let copy = note(id: original.id, fileName: "copied.md")
        let refreshed = copyFirst ? [copy, original] : [original, copy]

        #expect(target(for: selectedBeforeCapture, in: refreshed) == nil)
        #expect(target(for: copy.libraryIdentity, in: refreshed) == nil)
    }

    @Test
    func aMissingMovedOrReplacedSourceCannotBeSubstituted() {
        let original = note()
        let moved = note(id: original.id, fileName: "moved.md")
        let replaced = note(fileName: "original.md")

        #expect(target(for: original.libraryIdentity, in: []) == nil)
        #expect(target(for: original.libraryIdentity, in: [moved]) == nil)
        #expect(target(for: original.libraryIdentity, in: [replaced]) == nil)
    }

    @Test
    func switchingLibrariesCannotAdoptACopyOrUseStaleLibraryEntries() {
        let original = note()
        let otherLibrary = URL(fileURLWithPath: "/nook-fixtures/Other", isDirectory: true)
        var copied = original
        copied.fileURL = otherLibrary.appendingPathComponent("original.md")

        #expect(target(
            for: original.libraryIdentity, in: [copied], libraryURL: otherLibrary
        ) == nil)
        // Reloading is asynchronous, so old entries can briefly remain after
        // the active folder has already changed.
        #expect(target(
            for: original.libraryIdentity, in: [original], libraryURL: otherLibrary
        ) == nil)
        #expect(target(
            for: copied.libraryIdentity, in: [copied], libraryURL: otherLibrary
        ) == copied)
    }

    @Test
    func unsavedNotesAndDigestsAreNotRecordingDestinations() {
        var unsaved = note()
        unsaved.fileURL = nil
        var digest = note()
        digest.kind = .digest

        #expect(target(for: unsaved.libraryIdentity, in: [unsaved]) == nil)
        #expect(target(for: digest.libraryIdentity, in: [digest]) == nil)
    }

    @Test
    func permissionRestartKeepsTheSelectedFileIdentity() throws {
        let original = note()
        let resumed = try #require(MeetingCoordinator.pendingAttachmentIdentity(
            noteID: original.id.uuidString,
            filePath: original.libraryIdentity.filePath
        ))

        #expect(resumed == original.libraryIdentity)
        #expect(target(for: resumed, in: [original]) == original)
        let copy = note(id: original.id, fileName: "copied.md")
        #expect(target(for: resumed, in: [copy]) == nil)
        #expect(target(for: resumed, in: [original, copy]) == nil)
    }

    @Test
    func legacyAndMalformedPermissionDestinationsRequireASelection() {
        let id = UUID().uuidString
        let paths: [String?] = [
            nil, "", "relative.md", "/nook-fixtures/../other.md", "/bad\0name.md",
        ]
        for path in paths {
            #expect(MeetingCoordinator.pendingAttachmentIdentity(
                noteID: id, filePath: path
            ) == nil)
        }
        #expect(MeetingCoordinator.pendingAttachmentIdentity(
            noteID: "not-a-uuid", filePath: "/nook-fixtures/Library/original.md"
        ) == nil)
    }

    @Test
    func neitherSummaryPassWritesIntoARenamedOrCopiedUUID() {
        let scaffold = note()
        var otherFile = scaffold
        otherFile.fileURL = library.appendingPathComponent("different.md")
        let generated = SummaryResult(
            insights: MeetingInsights(
                title: "Synthetic plan review",
                summary: "The team reviewed a synthetic plan.",
                keyPoints: ["Review the plan"],
                decisions: [],
                actionItems: []
            ),
            failure: nil
        )

        #expect(MeetingCoordinator.mergingTranscriptFirstSummary(
            generated, scaffold: scaffold, current: otherFile
        ) == nil)
        #expect(MeetingCoordinator.mergingAppendedSessionSummary(
            generated, scaffold: scaffold, current: otherFile
        ) == nil)
        #expect(MeetingCoordinator.mergingTranscriptFirstSummary(
            generated, scaffold: scaffold, current: scaffold
        ) != nil)
        #expect(MeetingCoordinator.mergingAppendedSessionSummary(
            generated, scaffold: scaffold, current: scaffold
        ) != nil)
    }
}

struct RecordingLifecycleTests {
    @Test
    @MainActor
    func captureFinalizationTimesOutWithoutADelegateCallback() async {
        let waiter = CaptureFinalizationWaiter(timeout: .milliseconds(20))

        do {
            try await waiter.wait {}
            Issue.record("Expected capture finalization to time out")
        } catch CaptureError.finalizationTimedOut {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    @MainActor
    func cancellingCaptureFinalizationResumesTheWaiter() async {
        let waiter = CaptureFinalizationWaiter(timeout: .seconds(5))
        let task = Task { @MainActor in
            try await waiter.wait {}
        }
        await Task.yield()

        task.cancel()

        do {
            try await task.value
            Issue.record("Expected capture finalization cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func requestedStopWaitsForTheStreamAndRecordingFile() throws {
        var state = CaptureStopState(waitsForRecordingFinalization: true)

        state.receiveRecordingFinalization(.success(()))
        #expect(state.resolution == nil)

        state.receiveStreamStop(.success(()))
        try #require(state.resolution).get()
    }

    @Test
    func stoppingWhilePausedNeedsOnlyTheStreamToFinish() throws {
        var state = CaptureStopState(waitsForRecordingFinalization: false)

        state.receiveStreamStop(.success(()))

        try #require(state.resolution).get()
    }

    @Test
    func recordingFailureWaitsForTheStreamThenFailsTheStop() {
        var state = CaptureStopState(waitsForRecordingFinalization: true)

        state.receiveRecordingFinalization(
            .failure(CaptureError.recordingMissing)
        )
        #expect(state.resolution == nil)

        state.receiveStreamStop(.success(()))

        do {
            try #require(state.resolution).get()
            Issue.record("Expected the recording failure to fail the stop")
        } catch CaptureError.recordingMissing {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func artifactCleanupRemovesOnlyTheCurrentMeetingsSensitiveFiles() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(
                "NookRecordingCleanup-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: directory) }

        let id = UUID()
        let baseURL = directory.appendingPathComponent("\(id.uuidString).mp4")
        let draft = MeetingDraft(
            id: id,
            title: "Privacy review",
            sourceApp: "Manual",
            startedAt: .now,
            recordingURL: baseURL
        )
        let owned = [
            baseURL,
            directory.appendingPathComponent("\(id.uuidString).part-2.mp4"),
            directory.appendingPathComponent("\(id.uuidString).m4a"),
        ]
        let unrelated = [
            directory.appendingPathComponent("\(UUID().uuidString).mp4"),
            directory.appendingPathComponent("\(id.uuidString).txt"),
        ]
        for url in owned + unrelated {
            try Data("private".utf8).write(to: url)
        }

        let failures = RecordingArtifactCleanup.removeArtifacts(
            for: draft,
            fileManager: fileManager
        )

        #expect(failures.isEmpty)
        #expect(owned.allSatisfy { !fileManager.fileExists(atPath: $0.path) })
        #expect(unrelated.allSatisfy { fileManager.fileExists(atPath: $0.path) })
    }

    @Test
    func successfulCleanupCanPreserveUserRetainedAudio() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(
                "NookRetainedAudio-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: directory) }

        let id = UUID()
        let baseURL = directory.appendingPathComponent("\(id.uuidString).mp4")
        let audioURL = directory.appendingPathComponent("\(id.uuidString).m4a")
        let draft = MeetingDraft(
            id: id,
            title: "Retained audio",
            sourceApp: "Manual",
            startedAt: .now,
            recordingURL: baseURL
        )
        try Data("capture".utf8).write(to: baseURL)
        try Data("audio".utf8).write(to: audioURL)

        RecordingArtifactCleanup.removeArtifacts(
            for: draft,
            preserving: Set([audioURL]),
            fileManager: fileManager
        )

        #expect(!fileManager.fileExists(atPath: baseURL.path))
        #expect(fileManager.fileExists(atPath: audioURL.path))
    }

    @Test
    @MainActor
    func terminationStateTracksRecordingAndProcessingPhases() {
        let coordinator = MeetingCoordinator(
            store: MarkdownStore(),
            detector: MeetingDetector()
        )
        #expect(coordinator.terminationState == .inactive)

        coordinator.setPreviewState(
            phase: .recording(title: "Review", startedAt: .now),
            elapsed: 10,
            liveTranscript: .empty,
            audioLevel: 0.2
        )
        #expect(coordinator.terminationState == .recording)

        coordinator.setPreviewState(
            phase: .processing(.transcribing),
            elapsed: 10,
            liveTranscript: .empty,
            audioLevel: 0
        )
        #expect(coordinator.terminationState == .processing)
    }

    /// The recovery list offers recordings belonging to no saved note, which
    /// an in-flight recording matches for its whole life. Publishing its
    /// identifier is what stops the list inviting somebody to recover a
    /// meeting that is still being written.
    @Test
    @MainActor
    func theRecordingInFlightIsNamedWhileItRuns() {
        let coordinator = MeetingCoordinator(
            store: MarkdownStore(),
            detector: MeetingDetector()
        )

        #expect(coordinator.activeRecordingID == nil)

        let id = coordinator.startDraftForTesting()

        #expect(coordinator.activeRecordingID == id)

        coordinator.clearDraftForTesting()

        #expect(coordinator.activeRecordingID == nil)
    }

    @Test
    @MainActor
    func stopRequestedDuringPauseRunsWhenTheTransitionCompletes() {
        let coordinator = MeetingCoordinator(
            store: MarkdownStore(),
            detector: MeetingDetector()
        )
        coordinator.setPreviewState(
            phase: .recording(title: "Review", startedAt: .now),
            elapsed: 10,
            liveTranscript: .empty,
            audioLevel: 0.2
        )
        coordinator.setPauseTransitionForTesting(true)

        coordinator.stopRecording()

        #expect(coordinator.hasDeferredStopForTesting)
        #expect(coordinator.phase.isRecording)

        coordinator.completePauseTransitionForTesting()

        #expect(!coordinator.hasDeferredStopForTesting)
        guard case .processing = coordinator.phase else {
            Issue.record("Expected the deferred stop to enter processing")
            return
        }
    }
}

/// Processing failures used to delete the recording, so a Mac that took a
/// moment too long to finish writing a file cost the user the meeting. The
/// recording is now the one thing that must survive a failure, because when
/// processing fails it is the only copy of the conversation that exists.
@MainActor
struct PreservedRecordingTests {
    @Test
    func aFailureNamesTheFolderTheRecordingWasKeptIn() throws {
        let directory = URL.temporaryDirectory
            .appendingPathComponent("nook-preserved-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let recording = directory.appendingPathComponent("meeting.mp4")
        try Data("audio".utf8).write(to: recording)

        let notice = MeetingCoordinator.preservedRecordingNotice(
            for: [recording]
        )

        #expect(notice.contains(directory.path(percentEncoded: false)))
        #expect(notice.contains("kept"))
    }

    /// Nothing on disk means nothing to promise. Telling someone their audio
    /// was preserved when it was not is worse than saying nothing.
    @Test
    func nothingIsPromisedWhenNoRecordingSurvived() {
        let missing = URL.temporaryDirectory
            .appendingPathComponent("nook-missing-\(UUID().uuidString).mp4")

        #expect(MeetingCoordinator.preservedRecordingNotice(for: [missing]).isEmpty)
        #expect(MeetingCoordinator.preservedRecordingNotice(for: []).isEmpty)
    }
}

/// The failure notice depends on finding the recording on disk rather than on
/// the return value of the call that failed. When `capture.stop()` is what
/// threw, it returned nothing, and that is exactly when the user most needs to
/// be told where their meeting went.
@MainActor
struct FailedStopDiscoveryTests {
    private func draft(in directory: URL) -> MeetingDraft {
        MeetingDraft(
            id: UUID(),
            title: "Pricing review",
            sourceApp: "Manual",
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            recordingURL: directory
                .appendingPathComponent("\(UUID().uuidString).mp4")
        )
    }

    @Test
    func theRecordingIsFoundWhenTheStopCallReturnedNothing() throws {
        let directory = URL.temporaryDirectory
            .appendingPathComponent("nook-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let draft = draft(in: directory)
        // What ScreenCaptureKit leaves behind when finalization never finishes:
        // the audio is written, the file was simply never closed out.
        try Data("audio".utf8).write(to: draft.recordingURL)

        let found = RecordingArtifactCleanup.artifactURLs(for: draft)
        #expect(found.contains(draft.recordingURL))

        let notice = MeetingCoordinator.preservedRecordingNotice(
            for: Array(found)
        )
        #expect(notice.contains(directory.path(percentEncoded: false)))
    }

    /// Naming somebody else's meeting would be worse than naming none.
    @Test
    func anotherMeetingsRecordingIsNeverNamed() throws {
        let directory = URL.temporaryDirectory
            .appendingPathComponent("nook-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let mine = draft(in: directory)
        let theirs = draft(in: directory)
        try Data("mine".utf8).write(to: mine.recordingURL)
        try Data("theirs".utf8).write(to: theirs.recordingURL)

        let found = RecordingArtifactCleanup.artifactURLs(for: mine)

        #expect(found.contains(mine.recordingURL))
        #expect(!found.contains(theirs.recordingURL))
    }
}

/// Adopting a session recording as a note's audio is two moves, not one: the
/// old file is renamed out of the way, then the new one takes its place. The
/// window between them is where a recording can go missing, so what happens
/// when the second move fails is the whole behaviour.
struct AdoptedAudioRecoveryTests {
    private let prior = URL(fileURLWithPath: "/recordings/note.m4a")
    private let session = URL(fileURLWithPath: "/recordings/session.m4a")
    private let aside = URL(fileURLWithPath: "/recordings/note-unreadable-x.m4a")
    private let recoverable = URL(fileURLWithPath: "/recordings/fresh-id.m4a")

    private struct MoveFailed: Error {}

    /// Records every move attempted, and fails the ones named.
    private final class Moves {
        private(set) var attempted: [String] = []
        var failing: Set<String> = []

        func move(_ from: URL, _ to: URL) throws {
            let step = "\(from.lastPathComponent)->\(to.lastPathComponent)"
            attempted.append(step)
            if failing.contains(step) { throw MoveFailed() }
        }
    }

    @Test
    func theOrdinaryCaseSetsTheOldFileAsideAndMovesTheNewOneIn() throws {
        let moves = Moves()
        try MeetingCoordinator.adoptSessionAudio(
            priorExists: true,
            priorAudioURL: prior,
            sessionAudioURL: session,
            asideURL: aside,
            recoverableURL: recoverable,
            move: moves.move
        )
        #expect(
            moves.attempted == [
                "note.m4a->note-unreadable-x.m4a",
                "session.m4a->note.m4a"
            ]
        )
    }

    @Test
    func aFailedMoveInPutsTheNotesOwnAudioBack() {
        let moves = Moves()
        moves.failing = ["session.m4a->note.m4a"]

        // The failure is still reported: this sitting's audio did not land.
        #expect(throws: MoveFailed.self) {
            try MeetingCoordinator.adoptSessionAudio(
                priorExists: true,
                priorAudioURL: prior,
                sessionAudioURL: session,
                asideURL: aside,
                recoverableURL: recoverable,
                move: moves.move
            )
        }
        // The note keeps exactly the audio it had, rather than pointing at a
        // path with nothing in it while its recording sits under a name the
        // orphan scan is written to ignore.
        #expect(moves.attempted.last == "note-unreadable-x.m4a->note.m4a")
    }

    @Test
    func audioThatCannotGoBackIsGivenANameTheRecoveryScanLists() {
        let moves = Moves()
        moves.failing = [
            "session.m4a->note.m4a",
            "note-unreadable-x.m4a->note.m4a"
        ]

        var stranded: KeptAudioStranded?
        do {
            try MeetingCoordinator.adoptSessionAudio(
                priorExists: true,
                priorAudioURL: prior,
                sessionAudioURL: session,
                asideURL: aside,
                recoverableURL: recoverable,
                move: moves.move
            )
        } catch let error as KeptAudioStranded {
            stranded = error
        } catch {
            Issue.record("Expected the stranded audio to be reported.")
        }

        #expect(stranded?.strandedURL == recoverable)
        #expect(stranded?.isListedByRecoveryScan == true)
    }

    @Test
    func audioThatCannotBeMovedAtAllIsNamedToTheUser() {
        let moves = Moves()
        moves.failing = [
            "session.m4a->note.m4a",
            "note-unreadable-x.m4a->note.m4a",
            "note-unreadable-x.m4a->fresh-id.m4a"
        ]

        var stranded: KeptAudioStranded?
        do {
            try MeetingCoordinator.adoptSessionAudio(
                priorExists: true,
                priorAudioURL: prior,
                sessionAudioURL: session,
                asideURL: aside,
                recoverableURL: recoverable,
                move: moves.move
            )
        } catch let error as KeptAudioStranded {
            stranded = error
        } catch {
            Issue.record("Expected the stranded audio to be reported.")
        }

        // Nothing lists this name, so the notice is the only way the user
        // hears where their earlier audio went.
        #expect(stranded?.strandedURL == aside)
        #expect(stranded?.isListedByRecoveryScan == false)
    }

    @Test
    func aNoteWithNoAudioOfItsOwnHasNothingToPutBack() {
        let moves = Moves()
        moves.failing = ["session.m4a->note.m4a"]

        #expect(throws: MoveFailed.self) {
            try MeetingCoordinator.adoptSessionAudio(
                priorExists: false,
                priorAudioURL: prior,
                sessionAudioURL: session,
                asideURL: aside,
                recoverableURL: recoverable,
                move: moves.move
            )
        }
        #expect(moves.attempted == ["session.m4a->note.m4a"])
    }
}

/// Recordings kept after a failure must be findable again. Keeping audio the
/// user can never see would trade a rare catastrophe for a quiet one.
@MainActor
struct OrphanedRecordingTests {
    @Test
    func aRecordingGroupsWithItsPausedSegments() {
        let id = UUID()
        let directory = URL.temporaryDirectory
        let orphan = OrphanedRecording(
            id: id,
            urls: [
                directory.appendingPathComponent("\(id.uuidString).mp4"),
                directory.appendingPathComponent("\(id.uuidString).part-2.mp4"),
                directory.appendingPathComponent("\(id.uuidString).m4a")
            ],
            recordedAt: Date(timeIntervalSince1970: 1_000_000),
            byteSize: 3_000_000
        )

        #expect(orphan.captures.count == 2)
        #expect(orphan.extractedAudio?.pathExtension == "m4a")
        #expect(orphan.sizeLabel.contains("MB"))
    }

    /// Already-extracted audio is reused, because re-extracting is the slowest
    /// part of recovering a note and produces the same result.
    @Test
    func extractedAudioIsPreferredWhenItExists() {
        let id = UUID()
        let directory = URL.temporaryDirectory
        let withAudio = OrphanedRecording(
            id: id,
            urls: [
                directory.appendingPathComponent("\(id.uuidString).mp4"),
                directory.appendingPathComponent("\(id.uuidString).m4a")
            ],
            recordedAt: .distantPast,
            byteSize: 1
        )
        let captureOnly = OrphanedRecording(
            id: id,
            urls: [directory.appendingPathComponent("\(id.uuidString).mp4")],
            recordedAt: .distantPast,
            byteSize: 1
        )

        #expect(withAudio.extractedAudio != nil)
        #expect(captureOnly.extractedAudio == nil)
        #expect(captureOnly.captures.count == 1)
    }
}

/// A live recognizer can stop mid-meeting without reporting an error, leaving
/// a transcript that ends long before the audio does. Trusting it would save
/// hours of missing conversation as if complete, so coverage against the
/// recorded duration decides between the live transcript and a careful
/// saved-audio pass.
@MainActor
struct LiveTranscriptCoverageTests {
    private func segment(
        start: TimeInterval,
        duration: TimeInterval,
        source: TranscriptSegment.Source
    ) -> TranscriptSegment {
        TranscriptSegment(
            startTime: start,
            duration: duration,
            text: "Spoken words for coverage",
            source: source
        )
    }

    @Test
    func wordsEndingLongBeforeTheRecordingEndsAreNotTrusted() {
        let truncated = [
            segment(start: 0, duration: 60, source: .system),
            segment(start: 1_100, duration: 30, source: .system)
        ]

        // A two-hour meeting whose recognizer stopped around minute nineteen:
        // the words end near 19 minutes into audio that ran to 120.
        #expect(!MeetingCoordinator.liveSegmentsCoverRecording(
            truncated,
            recordedSeconds: 7_200
        ))
    }

    @Test
    func speechCoveringTheRecordingIsTrusted() {
        let covered = [
            segment(start: 0, duration: 60, source: .system),
            segment(start: 1_170, duration: 25, source: .system)
        ]

        #expect(MeetingCoordinator.liveSegmentsCoverRecording(
            covered,
            recordedSeconds: 1_200
        ))
    }

    /// Trailing silence after everyone stops talking must not by itself force
    /// re-transcription of a meeting whose recognizer stayed healthy. The tail
    /// window is measured between the tracks, not against the recording,
    /// precisely so a long closing silence stays ordinary.
    @Test
    func trailingSilenceIsStillCovered() {
        let trailingSilence = [segment(
            start: 0,
            duration: 2_700,
            source: .microphone
        )]

        #expect(MeetingCoordinator.liveSegmentsCoverRecording(
            trailingSilence,
            recordedSeconds: 3_600
        ))
    }

    /// The proportional rule alone accepted a track that stopped inside the
    /// last quarter while the other one carried on, which is twenty minutes of
    /// a two hour meeting saved as though it were the whole thing. Silence
    /// would have ended both tracks together; only one of them ending early
    /// means a recognizer died.
    @Test
    func aTrackStallingWhileTheOtherKeepsGoingIsNotTrusted() {
        let stalledLate = [
            segment(start: 0, duration: 60, source: .system),
            segment(start: 5_900, duration: 100, source: .system),
            segment(start: 7_100, duration: 50, source: .microphone)
        ]

        #expect(!MeetingCoordinator.liveSegmentsCoverRecording(
            stalledLate,
            recordedSeconds: 7_200
        ))
    }

    /// Both tracks falling quiet at the same point is a meeting ending, not a
    /// failure, however far from the end of the recording that point is.
    @Test
    func bothTracksGoingQuietTogetherIsAnOrdinaryEnding() {
        let quietEnding = [
            segment(start: 0, duration: 60, source: .system),
            segment(start: 5_800, duration: 200, source: .system),
            segment(start: 5_900, duration: 60, source: .microphone)
        ]

        #expect(MeetingCoordinator.liveSegmentsCoverRecording(
            quietEnding,
            recordedSeconds: 7_200
        ))
    }

    /// The tail window never shrinks below a minute and a half, so a short
    /// meeting is not condemned by one track pausing slightly earlier.
    @Test
    func aShortClosingPauseIsWithinTheTailWindow() {
        let brief = [
            segment(start: 0, duration: 200, source: .system),
            segment(start: 150, duration: 70, source: .microphone)
        ]

        #expect(MeetingCoordinator.liveSegmentsCoverRecording(
            brief,
            recordedSeconds: 240
        ))
    }

    /// The two tracks fail independently. A healthy microphone track must not
    /// mask system audio dying at minute twenty of a two-hour meeting.
    @Test
    func oneHealthyTrackCannotHideAnotherTrackStoppingEarly() {
        let mixedFate = [
            segment(start: 0, duration: 60, source: .system),
            segment(start: 7_100, duration: 40, source: .microphone)
        ]

        #expect(!MeetingCoordinator.liveSegmentsCoverRecording(
            mixedFate,
            recordedSeconds: 7_200
        ))
    }

    /// Judging very short meetings produces more false alarms than protection,
    /// so they always count as covered.
    @Test
    func veryShortRecordingsSkipTheCoverageJudgement() {
        let brief = [segment(start: 0, duration: 10, source: .system)]

        #expect(MeetingCoordinator.liveSegmentsCoverRecording(
            brief,
            recordedSeconds: 30
        ))
        #expect(MeetingCoordinator.liveSegmentsCoverRecording(
            [],
            recordedSeconds: 0
        ))
    }
}

/// A recognizer can die mid-meeting without reporting anything. Noticing while
/// the meeting is still running means the saved-audio pass is already the plan
/// by the time the recording stops.
@MainActor
struct StalledLiveTrackTests {
    private func segment(
        start: TimeInterval,
        source: TranscriptSegment.Source
    ) -> TranscriptSegment {
        TranscriptSegment(
            startTime: start,
            duration: 10,
            text: "Spoken words for the stall check",
            source: source
        )
    }

    @Test
    func aTrackThatStopsWhileTheOtherKeepsGoingIsFlagged() {
        let stalled = [
            segment(start: 0, source: .microphone),
            segment(start: 120, source: .microphone),
            segment(start: 0, source: .system),
            segment(start: 2_400, source: .system)
        ]

        #expect(MeetingCoordinator.liveTrackHasStalled(stalled))
    }

    /// Silence is ordinary. Only a gap longer than any natural pause counts,
    /// and a source that never produced a word is not judged at all: nobody
    /// speaking into the microphone is a normal meeting.
    @Test
    func ordinarySilenceAndAOneSidedMeetingAreNotFlagged() {
        let brieflyQuiet = [
            segment(start: 0, source: .microphone),
            segment(start: 200, source: .microphone),
            segment(start: 400, source: .system)
        ]
        let oneSided = [
            segment(start: 0, source: .system),
            segment(start: 3_000, source: .system)
        ]

        #expect(!MeetingCoordinator.liveTrackHasStalled(brieflyQuiet))
        #expect(!MeetingCoordinator.liveTrackHasStalled(oneSided))
        #expect(!MeetingCoordinator.liveTrackHasStalled([]))
    }

    @Test
    func aStalledTrackClearsTheCompletenessFlagWhileRecording() {
        let coordinator = MeetingCoordinator(
            store: MarkdownStore(),
            detector: MeetingDetector()
        )
        coordinator.setPreviewState(
            phase: .recording(title: "Review", startedAt: .now),
            elapsed: 2_400,
            liveTranscript: .empty,
            audioLevel: 0.2
        )
        coordinator.setLiveTranscriptCompleteForTesting(true)

        coordinator.receiveLiveTranscriptForTesting(
            LiveTranscriptState(segments: [
                segment(start: 0, source: .microphone),
                segment(start: 120, source: .microphone),
                segment(start: 2_400, source: .system)
            ])
        )

        #expect(!coordinator.liveTranscriptIsCompleteForTesting)
    }
}

/// The live summary restarted on every caption publish, so on a meeting where
/// anybody was talking it never finished, and the spinner it turned on before
/// the pass never turned off.
@MainActor
struct LiveSummarySchedulingTests {
    private func recording() -> MeetingCoordinator {
        let coordinator = MeetingCoordinator(
            store: MarkdownStore(),
            detector: MeetingDetector()
        )
        coordinator.setPreviewState(
            phase: .recording(title: "Review", startedAt: .now),
            elapsed: 120,
            liveTranscript: .empty,
            audioLevel: 0.2
        )
        return coordinator
    }

    private func state(_ count: Int) -> LiveTranscriptState {
        LiveTranscriptState(
            segments: (0..<count).map { index in
                TranscriptSegment(
                    startTime: Double(index) * 5,
                    duration: 4,
                    text: "Line \(index) about the migration plan and its owners."
                )
            }
        )
    }

    @Test
    func aCaptionUpdateNeverCancelsThePassAlreadyRunning() {
        let coordinator = recording()

        coordinator.receiveLiveTranscriptForTesting(state(6))
        #expect(coordinator.liveSummaryIsRunningForTesting)

        coordinator.receiveLiveTranscriptForTesting(state(9))
        coordinator.receiveLiveTranscriptForTesting(state(14))

        #expect(coordinator.liveSummaryIsRunningForTesting)
        // Nothing has reached the model yet, so nothing claims to be
        // refreshing. The flag used to be raised here and never lowered.
        #expect(!coordinator.liveSummaryIsRefreshing)

        coordinator.setPreviewState(
            phase: .idle,
            elapsed: 0,
            liveTranscript: .empty,
            audioLevel: 0
        )
    }

    /// A refresh the user asked for waits its turn instead of being dropped,
    /// and instead of cancelling the pass in flight.
    @Test
    func aForcedRefreshQueuesBehindTheRunningPass() {
        let coordinator = recording()
        coordinator.receiveLiveTranscriptForTesting(state(6))

        coordinator.refreshLiveSummary()

        #expect(coordinator.liveSummaryIsRunningForTesting)
        #expect(coordinator.liveSummaryForceIsQueuedForTesting)

        coordinator.setPreviewState(
            phase: .idle,
            elapsed: 0,
            liveTranscript: .empty,
            audioLevel: 0
        )
    }

    /// Each refresh costs more as the meeting grows while adding less, so a
    /// two hour meeting must not summarize itself every half minute.
    @Test
    func refreshesBackOffAsTheMeetingGrows() {
        let short = MeetingCoordinator.liveSummaryInterval(forSegmentCount: 20)
        let medium = MeetingCoordinator.liveSummaryInterval(forSegmentCount: 150)
        let long = MeetingCoordinator.liveSummaryInterval(forSegmentCount: 900)

        #expect(short < medium)
        #expect(medium < long)
    }
}

/// The audio meter, the clock and the captions publish many times a second
/// while a meeting runs. While they lived on the coordinator every view that
/// held it, including the whole Library window, re-laid itself out on each
/// tick and pinned a core (1.19.0 and 1.20.0 shipped that way). They now
/// publish through `MeetingCoordinator.live`, so only the small views that
/// draw a level, a caption or a clock pay for them.
@MainActor
struct LiveSignalPublicationTests {
    /// Fixed so a second `setPreviewState` can repeat the identical phase.
    private static let startedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let phase = MeetingPhase.recording(
        title: "Review",
        startedAt: startedAt
    )

    private func recording() -> MeetingCoordinator {
        // A stubbed loader and a scratch directory keep this suite off the
        // real notes folder. The bare `MarkdownStore()` reloads it from disk
        // on the main actor, and these assertions need nothing from it, so
        // paying that cost would only add main-actor contention to a parallel
        // run for no coverage.
        let store = MarkdownStore(noteLoader: { _, _ in
            .success((notes: [], issues: []))
        })
        store.storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NookLiveSignals-\(UUID().uuidString)",
                isDirectory: true
            )
        let coordinator = MeetingCoordinator(
            store: store,
            detector: MeetingDetector()
        )
        coordinator.setPreviewState(
            phase: Self.phase,
            elapsed: 120,
            liveTranscript: .empty,
            audioLevel: 0.2
        )
        return coordinator
    }

    private func caption(_ text: String) -> LiveTranscriptState {
        LiveTranscriptState(
            segments: [TranscriptSegment(startTime: 0, duration: 4, text: text)]
        )
    }

    @Test
    func aNewCaptionPublishesOnTheLiveSignalsAndNotOnTheCoordinator() {
        let coordinator = recording()
        var coordinatorPublications = 0
        var livePublications = 0
        let coordinatorObservation = coordinator.objectWillChange
            .sink { coordinatorPublications += 1 }
        let liveObservation = coordinator.live.objectWillChange
            .sink { livePublications += 1 }
        defer {
            coordinatorObservation.cancel()
            liveObservation.cancel()
        }

        // One segment is well short of the four new lines the live summary
        // waits for, so nothing else is scheduled: only the caption changes.
        coordinator.receiveLiveTranscriptForTesting(
            caption("We agreed on the owners.")
        )

        #expect(livePublications == 1)
        #expect(coordinatorPublications == 0)
        #expect(coordinator.liveTranscript.latestText == "We agreed on the owners.")
        #expect(coordinator.live.liveTranscript == coordinator.liveTranscript)
    }

    @Test
    func meterAndClockTicksPublishOnTheLiveSignalsAndReadBackThroughTheCoordinator() {
        let coordinator = recording()
        var coordinatorPublications = 0
        var livePublications = 0
        let coordinatorObservation = coordinator.objectWillChange
            .sink { coordinatorPublications += 1 }
        let liveObservation = coordinator.live.objectWillChange
            .sink { livePublications += 1 }
        defer {
            coordinatorObservation.cancel()
            liveObservation.cancel()
        }

        coordinator.setPreviewState(
            phase: Self.phase,
            elapsed: 42,
            liveTranscript: .empty,
            audioLevel: 0.5
        )

        // `setPreviewState` writes elapsed, the transcript and the level, one
        // publication each on the live signals. It also re-assigns `phase`,
        // `isPaused` and `liveInsights` on the coordinator every call, and a
        // `@Published` assignment publishes even when the value is unchanged,
        // so the coordinator sees exactly those three slow writes and nothing
        // for the fast values. Moving a fast value back onto the coordinator
        // would make it four here and two above.
        #expect(livePublications == 3)
        #expect(coordinatorPublications == 3)

        #expect(coordinator.elapsed == 42)
        #expect(coordinator.audioLevel == 0.5)
        #expect(coordinator.live.elapsed == 42)
        #expect(coordinator.live.audioLevel == 0.5)
    }

    @Test
    func pausingStillPublishesOnTheCoordinator() {
        let coordinator = recording()
        // Watch the pause property itself rather than `objectWillChange`,
        // which the phase assignment inside `setPreviewState` would satisfy
        // on its own; this proves pause state still travels through the
        // coordinator after the fast signals moved off it.
        var pausePublications = 0
        let pauseObservation = coordinator.$isPaused
            .dropFirst()
            .sink { _ in pausePublications += 1 }
        defer { pauseObservation.cancel() }

        coordinator.setPreviewState(
            phase: Self.phase,
            elapsed: 120,
            liveTranscript: .empty,
            audioLevel: 0.2,
            isPaused: true
        )

        #expect(coordinator.isPaused)
        #expect(pausePublications == 1)
    }
}

/// Summarizing had no deadline at all, so a wedged on-device model held the
/// save, and therefore a quit, open indefinitely.
@MainActor
struct SummaryDeadlineTests {
    @Test
    func cancellingQuitAfterMeetingCleanupRestoresTheOrdinarySummaryBudget() async {
        let store = MarkdownStore(noteLoader: { _, _ in
            .success((notes: [], issues: []))
        })
        let coordinator = MeetingCoordinator(store: store, detector: MeetingDetector())
        let ordinaryBudget = coordinator.summaryDeadline(forTranscriptCharacters: 120_000)

        #expect(await coordinator.prepareForApplicationTermination())
        #expect(coordinator.summaryDeadline(forTranscriptCharacters: 120_000)
                == MeetingCoordinator.summaryQuitDeadline)

        coordinator.cancelApplicationTermination()

        #expect(coordinator.summaryDeadline(forTranscriptCharacters: 120_000) == ordinaryBudget)
        #expect(ordinaryBudget > MeetingCoordinator.summaryQuitDeadline)
        #expect(coordinator.terminationState == .inactive)
    }

    @Test
    func cancellingADeadlineWaitResumesImmediately() async {
        let signal = DeadlineSignal<Int>()
        var finished = false
        let task = Task { @MainActor in
            let value = await signal.wait()
            finished = true
            return value
        }
        await Task.yield()

        task.cancel()
        try? await Task.sleep(for: .milliseconds(20))

        let cancellationFinishedTheWait = finished
        if !cancellationFinishedTheWait {
            // Let a broken implementation unwind so the suite reports the
            // failed expectation instead of hanging forever.
            signal.signal(42)
        }
        #expect(cancellationFinishedTheWait)
        #expect(await task.value == nil)
    }

    @Test
    func longerMeetingsAreAllowedLongerButNotForever() {
        let short = MeetingCoordinator.summaryDeadline(
            forTranscriptCharacters: 2_000,
            isTerminating: false
        )
        let long = MeetingCoordinator.summaryDeadline(
            forTranscriptCharacters: 120_000,
            isTerminating: false
        )
        let absurd = MeetingCoordinator.summaryDeadline(
            forTranscriptCharacters: 10_000_000,
            isTerminating: false
        )

        #expect(short >= 90)
        #expect(long > short)
        #expect(absurd <= 900)
    }

    /// Nobody waits minutes for an application to close.
    @Test
    func quittingCollapsesTheBudget() {
        #expect(
            MeetingCoordinator.summaryDeadline(
                forTranscriptCharacters: 500_000,
                isTerminating: true
            ) == MeetingCoordinator.summaryQuitDeadline
        )
        #expect(MeetingCoordinator.summaryQuitDeadline < 60)
    }

    @Test
    func progressFromAnOlderSummaryPassCannotUpdateTheCurrentIndicator() {
        #expect(
            MeetingCoordinator.shouldApplySummaryProgress(
                generation: 4,
                currentGeneration: 4
            )
        )
        #expect(
            !MeetingCoordinator.shouldApplySummaryProgress(
                generation: 4,
                currentGeneration: 5
            )
        )
    }

    @Test
    func aLongSummaryTellsTheUserWhichPartItIsOn() {
        let coordinator = MeetingCoordinator(
            store: MarkdownStore(),
            detector: MeetingDetector()
        )
        coordinator.setPreviewState(
            phase: .processing(.summarizing),
            elapsed: 0,
            liveTranscript: .empty,
            audioLevel: 0
        )

        #expect(coordinator.processingDetail == MeetingPhase.ProcessingStep.summarizing.displaySentence)

        coordinator.setSummaryProgressForTesting(
            SummaryProgress(part: 3, total: 12)
        )

        #expect(coordinator.processingDetail.contains("part 3 of 12"))
    }
}

/// A completed transcript is useful immediately, even while the on-device
/// summary pass is still running. Enrichment is optimistic so edits made in
/// the meantime stay with the note.
@MainActor
struct TranscriptFirstFinalizationTests {
    private func draft() -> MeetingDraft {
        MeetingDraft(
            id: UUID(),
            title: "Meeting Tue 2:03 PM",
            sourceApp: "Manual",
            startedAt: Date(timeIntervalSince1970: 1_000),
            recordingURL: URL(fileURLWithPath: "/tmp/meeting.mp4")
        )
    }

    private func transcript() -> [TranscriptSegment] {
        [
            TranscriptSegment(
                startTime: 0,
                duration: 12,
                text: "The team approved the revised launch plan."
            )
        ]
    }

    private func generatedResult(failure: SummaryService.FailureReason? = nil)
        -> SummaryResult {
        SummaryResult(
            insights: MeetingInsights(
                title: "Launch planning",
                summary: "The team approved the revised launch plan.",
                keyPoints: ["Launch plan approved"],
                decisions: ["Use the revised launch plan"],
                actionItems: ["Share the launch plan"]
            ),
            failure: failure
        )
    }

    @Test
    func scaffoldCarriesUsefulDeterministicMeetingContent() {
        let noteDraft = draft()
        let transcript = transcript()
        let moments = [MeetingMoment(offset: 4)]
        let endedAt = Date(timeIntervalSince1970: 1_020)
        let scaffold = MeetingCoordinator.transcriptFirstScaffold(
            for: noteDraft,
            transcript: transcript,
            personalNotes: "Ask about the launch owner.",
            moments: moments,
            endedAt: endedAt
        )
        let fallback = SummaryService.fallbackInsights(
            transcript: transcript,
            fallbackTitle: noteDraft.title
        )

        #expect(scaffold.id == noteDraft.id)
        #expect(scaffold.kind == .meeting)
        #expect(scaffold.title == fallback.title)
        #expect(scaffold.summary == fallback.summary)
        #expect(scaffold.transcript == transcript)
        #expect(scaffold.personalNotes == "Ask about the launch owner.")
        #expect(scaffold.moments == moments)
        #expect(scaffold.startedAt == noteDraft.startedAt)
        #expect(scaffold.endedAt == endedAt)
        #expect(scaffold.sourceApp == noteDraft.sourceApp)
        #expect(scaffold.fileURL == nil)
    }

    @Test
    func emptyTranscriptKeepsTheExistingNoSpeechResult() {
        let noteDraft = draft()
        let scaffold = MeetingCoordinator.transcriptFirstScaffold(
            for: noteDraft,
            transcript: [],
            personalNotes: "",
            moments: [],
            endedAt: Date(timeIntervalSince1970: 1_020)
        )

        #expect(scaffold.title == noteDraft.title)
        #expect(scaffold.summary == "No speech was detected in this recording.")
        #expect(scaffold.keyPoints.isEmpty)
        #expect(scaffold.decisions.isEmpty)
        #expect(scaffold.actionItems.isEmpty)
    }

    @Test
    func enrichmentChangesOnlyFieldsStillEqualToTheScaffold() {
        let noteDraft = draft()
        var scaffold = MeetingCoordinator.transcriptFirstScaffold(
            for: noteDraft,
            transcript: transcript(),
            personalNotes: "Original notes",
            moments: [MeetingMoment(offset: 4)],
            endedAt: Date(timeIntervalSince1970: 1_020)
        )
        scaffold.fileURL = URL(fileURLWithPath: "/tmp/original.md")
        var current = scaffold
        current.title = "Renamed while processing"
        current.keyPoints = ["A hand-written point"]
        current.actionItems = ["A hand-written action"]
        current.completedActionItems = ["A hand-written action"]
        current.personalNotes = "Notes added while processing"
        current.moments = [MeetingMoment(offset: 9)]
        current.extraSections = [
            ExtraSection(
                heading: "## Handwritten",
                body: "Preserve this section.",
                anchor: nil
            )
        ]
        current.fileModified = Date(timeIntervalSince1970: 1_030)

        let merged = MeetingCoordinator.mergingTranscriptFirstSummary(
            generatedResult(),
            scaffold: scaffold,
            current: current
        )

        #expect(merged?.title == current.title)
        #expect(merged?.summary == "The team approved the revised launch plan.")
        #expect(merged?.keyPoints == current.keyPoints)
        #expect(merged?.decisions == ["Use the revised launch plan"])
        #expect(merged?.actionItems == current.actionItems)
        #expect(merged?.completedActionItems == current.completedActionItems)
        #expect(merged?.personalNotes == current.personalNotes)
        #expect(merged?.transcript == current.transcript)
        #expect(merged?.moments == current.moments)
        #expect(merged?.extraSections == current.extraSections)
        #expect(merged?.fileURL == current.fileURL)
        #expect(merged?.fileModified == current.fileModified)
    }

    @Test
    func aChangedCheckboxPreventsReplacingTheActionList() {
        let noteDraft = draft()
        var scaffold = MeetingCoordinator.transcriptFirstScaffold(
            for: noteDraft,
            transcript: transcript(),
            personalNotes: "Original notes",
            moments: [],
            endedAt: Date(timeIntervalSince1970: 1_020)
        )
        scaffold.actionItems = ["Review the launch plan"]

        var current = scaffold
        current.completedActionItems = ["Review the launch plan"]

        let merged = MeetingCoordinator.mergingTranscriptFirstSummary(
            generatedResult(),
            scaffold: scaffold,
            current: current
        )

        #expect(merged?.actionItems == current.actionItems)
        #expect(merged?.completedActionItems == current.completedActionItems)
    }

    @Test
    func changedTranscriptPreventsApplyingClaimsFromAnOlderSource() {
        let noteDraft = draft()
        let scaffold = MeetingCoordinator.transcriptFirstScaffold(
            for: noteDraft,
            transcript: transcript(),
            personalNotes: "Original notes",
            moments: [],
            endedAt: Date(timeIntervalSince1970: 1_020)
        )
        var current = scaffold
        current.transcript = [
            TranscriptSegment(
                startTime: 0,
                duration: 12,
                text: "A different transcript was written by the user."
            )
        ]

        let merged = MeetingCoordinator.mergingTranscriptFirstSummary(
            generatedResult(),
            scaffold: scaffold,
            current: current
        )

        #expect(merged == current)
    }

    @Test
    func fallbackResultLeavesTheTranscriptFirstNoteUntouched() {
        let noteDraft = draft()
        let scaffold = MeetingCoordinator.transcriptFirstScaffold(
            for: noteDraft,
            transcript: transcript(),
            personalNotes: "Original notes",
            moments: [],
            endedAt: Date(timeIntervalSince1970: 1_020)
        )
        var current = scaffold
        current.personalNotes = "Changed while the model was unavailable"

        let merged = MeetingCoordinator.mergingTranscriptFirstSummary(
            generatedResult(failure: .modelBusy),
            scaffold: scaffold,
            current: current
        )

        #expect(merged == current)
    }

    @Test
    func deletedNoteIsNeverRecreatedByEnrichment() {
        let noteDraft = draft()
        let scaffold = MeetingCoordinator.transcriptFirstScaffold(
            for: noteDraft,
            transcript: transcript(),
            personalNotes: "Original notes",
            moments: [],
            endedAt: Date(timeIntervalSince1970: 1_020)
        )

        #expect(
            MeetingCoordinator.mergingTranscriptFirstSummary(
                generatedResult(),
                scaffold: scaffold,
                current: nil
            ) == nil
        )

        var different = scaffold
        different = MeetingNote(
            id: UUID(),
            kind: different.kind,
            title: different.title,
            startedAt: different.startedAt,
            endedAt: different.endedAt,
            sourceApp: different.sourceApp,
            summary: different.summary,
            keyPoints: different.keyPoints,
            decisions: different.decisions,
            actionItems: different.actionItems,
            completedActionItems: different.completedActionItems,
            personalNotes: different.personalNotes,
            transcript: different.transcript,
            moments: different.moments,
            sessions: different.sessions,
            audioStart: different.audioStart,
            extraSections: different.extraSections,
            fileURL: different.fileURL,
            fileModified: different.fileModified
        )
        #expect(
            MeetingCoordinator.mergingTranscriptFirstSummary(
                generatedResult(),
                scaffold: scaffold,
                current: different
            ) == nil
        )
    }
}

/// Enrichment holds an older scaffold while another writer can publish a
/// newer revision. Canonically equal text is not permission to replace that
/// newer writing. Exercise the final save as well as the in-memory merge.
@MainActor
struct RecordingEnrichmentExactEditTests {
    private enum Field: CaseIterable, Equatable {
        case title, summary, keyPoints, decisions, actionItems
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NookEnrichmentExact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func read(_ url: URL) throws -> MeetingNote {
        let source = try String(contentsOf: url, encoding: .utf8)
        return try #require(MarkdownCodec.decode(source, fileURL: url))
    }

    private func result() -> SummaryResult {
        SummaryResult(insights: MeetingInsights(
            title: "Generated review",
            summary: "A newly generated summary.",
            keyPoints: ["A newly generated point"],
            decisions: ["A newly generated decision"],
            actionItems: ["A newly generated action"]
        ), failure: nil)
    }

    private func enrich(_ result: SummaryResult, scaffold: MeetingNote, current: MeetingNote, appended: Bool) throws -> MeetingNote {
        if appended {
            return try #require(MeetingCoordinator.mergingAppendedSessionSummary(
                result, scaffold: scaffold, current: current
            ))
        }
        return try #require(MeetingCoordinator.mergingTranscriptFirstSummary(
            result, scaffold: scaffold, current: current
        ))
    }

    private func value(_ field: Field, in note: MeetingNote) -> String {
        switch field {
        case .title: note.title
        case .summary: note.summary
        case .keyPoints: note.keyPoints.joined(separator: "\n")
        case .decisions: note.decisions.joined(separator: "\n")
        case .actionItems: note.actionItems.joined(separator: "\n")
        }
    }

    @Test(arguments: [false, true], [false, true])
    func aFreshUnicodeOnlyEditSurvivesEitherDelayedEnrichment(appended: Bool, reverseNormalization: Bool) throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MarkdownStore(noteLoader: { _, _ in .success((notes: [], issues: [])) })
        store.storageURL = root
        let before = reverseNormalization ? "Cafe\u{301}" : "Café"
        let after = reverseNormalization ? "Café" : "Cafe\u{301}"
        #expect(before == after)
        #expect(!before.utf8.elementsEqual(after.utf8))

        for field in Field.allCases {
            let saved = try store.save(MeetingNote(
                title: "\(before) title", startedAt: Date(timeIntervalSince1970: 1_000),
                endedAt: Date(timeIntervalSince1970: 1_120), sourceApp: "Synthetic",
                summary: "\(before) summary", keyPoints: ["\(before) point"],
                decisions: ["\(before) decision"], actionItems: ["\(before) action"],
                completedActionItems: ["\(before) action"],
                personalNotes: "Retain my exact words.\nSecond line.",
                transcript: [TranscriptSegment(startTime: 0, duration: 0, text: "The review is ready.")]
            ))
            let file = try #require(saved.fileURL)
            let scaffold = try read(file)
            let pendingResult = result()
            // The result belongs to the old scaffold. An external edit lands
            // before that delayed result is applied, then the caller sees its
            // fresh revision, just as a reload supplies in the real pipeline.
            var edit = scaffold
            switch field {
            case .title: edit.title = "\(after) title"
            case .summary: edit.summary = "\(after) summary"
            case .keyPoints: edit.keyPoints = ["\(after) point"]
            case .decisions: edit.decisions = ["\(after) decision"]
            case .actionItems: edit.actionItems = ["\(after) action"]
            }
            try Data(MarkdownCodec.encode(edit).utf8).write(to: file)
            let current = try read(file)
            #expect(current.fileRevision != scaffold.fileRevision)
            #expect(current.transcript == scaffold.transcript)
            let merged = try enrich(pendingResult, scaffold: scaffold, current: current, appended: appended)
            #expect(value(field, in: merged).utf8.elementsEqual(value(field, in: current).utf8))
            #expect(merged.id == current.id)
            #expect(merged.fileURL == current.fileURL)
            #expect(merged.fileRevision == current.fileRevision)
            #expect(merged.personalNotes.utf8.elementsEqual(current.personalNotes.utf8))
            if field == .summary {
                #expect(merged.decisions == pendingResult.insights.decisions)
            } else {
                #expect(merged.summary == pendingResult.insights.summary)
            }
            let persisted = try store.save(merged)
            let readBack = try read(file)
            #expect(value(field, in: readBack).utf8.elementsEqual(value(field, in: current).utf8))
            #expect(readBack.fileRevision == persisted.fileRevision)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func unicodeOnlyTranscriptChangesRejectOldClaims(appended: Bool, reverseNormalization: Bool) throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Synthetic.md")
        let before = reverseNormalization ? "Cafe\u{301}" : "Café"
        let after = reverseNormalization ? "Café" : "Cafe\u{301}"
        let source = MeetingNote(
            title: "Synthetic review", startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_120), sourceApp: "Synthetic",
            summary: "Keep this summary.",
            transcript: [TranscriptSegment(startTime: 0, duration: 0, text: "\(before) review.")]
        )
        try Data(MarkdownCodec.encode(source).utf8).write(to: file)
        let scaffold = try read(file)
        let changed = MarkdownCodec.encode(source).replacingOccurrences(of: before, with: after)
        let changedBytes = Data(changed.utf8)
        try changedBytes.write(to: file)
        let current = try read(file)
        // Decoded segment IDs remain stable, so canonical array equality
        // alone cannot notice that the generation input's bytes changed.
        #expect(current.transcript == scaffold.transcript)
        #expect(current.fileRevision != scaffold.fileRevision)
        let merged = try enrich(result(), scaffold: scaffold, current: current, appended: appended)
        #expect(Data(MarkdownCodec.encode(merged).utf8) == changedBytes)
        #expect(merged.fileRevision == current.fileRevision)
        #expect(try Data(contentsOf: file) == changedBytes)
    }
}

private actor AppendedAudioTestGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func hold() async {
        entered = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters = []
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilHeld() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
struct AppendedAudioOwnershipTests {
    private struct Fixture {
        let root: URL
        let prior: URL
        let session: URL
        let draft: MeetingDraft
        let priorBytes = Data("Synthetic prior audio.".utf8)
        let sessionBytes = Data("Synthetic session audio.".utf8)
        let captureBytes = Data("Synthetic raw capture.".utf8)

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("NookAppendAudio-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let id = UUID()
            prior = root.appendingPathComponent("\(UUID().uuidString).m4a")
            session = root.appendingPathComponent("\(id.uuidString).m4a")
            draft = MeetingDraft(
                id: id, title: "Synthetic append", sourceApp: "Synthetic",
                startedAt: Date(timeIntervalSince1970: 1_000),
                recordingURL: root.appendingPathComponent("\(id.uuidString).mp4")
            )
            try priorBytes.write(to: prior)
            try sessionBytes.write(to: session)
            try captureBytes.write(to: draft.recordingURL)
        }

        func sources() async throws -> MeetingCoordinator.AppendedAudioSources {
            try await MeetingCoordinator.inspectAppendedAudio(
                priorAudioURL: prior, sessionAudioURL: session, measure: { _ in 17 }
            )
        }
    }

    @Test(arguments: [false, true], [false, true])
    func aRecordingChangedDuringMeasurementCannotSupplyTheAppendOffset(changeSession: Bool, replaceFile: Bool) async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = AppendedAudioTestGate()
        let work = Task {
            try await MeetingCoordinator.inspectAppendedAudio(
                priorAudioURL: fixture.prior, sessionAudioURL: fixture.session,
                measure: { _ in await gate.hold(); return 17 }
            )
        }
        await gate.waitUntilHeld()
        let changed = changeSession ? fixture.session : fixture.prior
        let newBytes = Data("A different synthetic recording, retained exactly.".utf8)
        do {
            try newBytes.write(to: changed, options: replaceFile ? .atomic : [])
        } catch {
            await gate.release()
            _ = try? await work.value
            throw error
        }
        await gate.release()
        do {
            _ = try await work.value
            Issue.record("A measured duration from a changed source must not reach the append.")
        } catch {
            #expect(error as? NoteCombiner.CombineError == .audioChanged)
        }
        #expect(try Data(contentsOf: changed) == newBytes)
        #expect(try Data(contentsOf: changeSession ? fixture.prior : fixture.session)
            == (changeSession ? fixture.priorBytes : fixture.sessionBytes))
        #expect(try Data(contentsOf: fixture.draft.recordingURL) == fixture.captureBytes)
    }

    @Test(arguments: [false, true], [false, true])
    func changedAudioIsNotReplacedByACombinationOfOlderBytes(changeSession: Bool, replaceFile: Bool) async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sources = try await fixture.sources()
        let gate = AppendedAudioTestGate()
        let oldCombined = fixture.priorBytes + fixture.sessionBytes
        let work = Task {
            try await MeetingCoordinator.concatenateAppendedAudio(
                sources,
                extract: { inputs, destination in
                    #expect(inputs == [fixture.prior, fixture.session])
                    try oldCombined.write(to: destination)
                    await gate.hold()
                },
                validatingBeforeReplacement: {}
            )
        }
        await gate.waitUntilHeld()
        let changed = changeSession ? fixture.session : fixture.prior
        let newBytes = Data("Newer synthetic audio must remain at its original path.".utf8)
        do {
            try newBytes.write(to: changed, options: replaceFile ? .atomic : [])
        } catch {
            await gate.release()
            _ = try? await work.value
            throw error
        }
        await gate.release()
        do {
            try await work.value
            Issue.record("An old combination must not replace either changed recording.")
        } catch {
            #expect(error as? NoteCombiner.CombineError == .audioChanged)
        }
        // Exercise the actual cleanup policy used on placement failure. It is
        // independent of the normal retention preference: the failed append
        // still owes its original capture and extracted session to recovery.
        let captureURLs = [fixture.draft.recordingURL]
        let preserved = MeetingCoordinator.sessionArtifactsAfterAudioFailure(
            draft: fixture.draft, recordingURLs: captureURLs, sessionAudioURL: fixture.session
        )
        let failures = RecordingArtifactCleanup.removeArtifacts(
            for: fixture.draft, additionalURLs: captureURLs + [fixture.session], preserving: preserved
        )
        #expect(failures.isEmpty)
        #expect(try Data(contentsOf: changed) == newBytes)
        #expect(try Data(contentsOf: changeSession ? fixture.prior : fixture.session)
            == (changeSession ? fixture.priorBytes : fixture.sessionBytes))
        #expect(try Data(contentsOf: fixture.draft.recordingURL) == fixture.captureBytes)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        #expect(!remaining.contains { $0.hasPrefix("combined-") })
    }

    @Test
    func losingTheNoteOwnerDuringCombinationLeavesBothRecordings() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sources = try await fixture.sources()
        do {
            try await MeetingCoordinator.concatenateAppendedAudio(
                sources,
                extract: { _, destination in
                    try (fixture.priorBytes + fixture.sessionBytes).write(to: destination)
                },
                validatingBeforeReplacement: { throw CocoaError(.fileNoSuchFile) }
            )
            Issue.record("A vanished note owner must refuse the audio replacement.")
        } catch {
            #expect((error as NSError).code == CocoaError.fileNoSuchFile.rawValue)
        }
        #expect(try Data(contentsOf: fixture.prior) == fixture.priorBytes)
        #expect(try Data(contentsOf: fixture.session) == fixture.sessionBytes)
    }

    @Test
    func unchangedAudioStillCombinesAfterItsOwnerIsValidated() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sources = try await fixture.sources()
        let combined = fixture.priorBytes + fixture.sessionBytes
        try await MeetingCoordinator.concatenateAppendedAudio(
            sources,
            extract: { _, destination in try combined.write(to: destination) },
            validatingBeforeReplacement: {}
        )
        #expect(try Data(contentsOf: fixture.prior) == combined)
        #expect(try Data(contentsOf: fixture.session) == fixture.sessionBytes)
        #expect(sources.priorDuration == 17)
    }
}

/// Recording into a note regenerated its title and replaced its action items,
/// so a name the user chose and a commitment they were still tracking both
/// disappeared because a second sitting did not mention them again.
@MainActor
struct AppendedSessionTests {
    private func summaryScaffold() -> MeetingNote {
        MeetingNote(
            title: "Meeting Wed 2:03 PM",
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_120),
            sourceApp: "Manual",
            summary: "Earlier summary",
            keyPoints: ["Earlier point"],
            decisions: ["Earlier decision"],
            actionItems: ["Book the load test window"],
            personalNotes: "Keep this note",
            transcript: [
                TranscriptSegment(
                    startTime: 0,
                    duration: 12,
                    text: "The team approved the migration plan."
                )
            ]
        )
    }

    private func generatedSummary() -> SummaryResult {
        SummaryResult(
            insights: MeetingInsights(
                title: "Migration plan review",
                summary: "The migration plan was approved.",
                keyPoints: ["Migration is ready"],
                decisions: ["Proceed with migration"],
                actionItems: ["Draft the rollback note"]
            ),
            failure: nil
        )
    }

    @Test
    func aTitleTheUserChoseSurvivesASecondSitting() {
        #expect(
            MeetingCoordinator.mergedTitle(
                existing: "Pricing rework with Ana",
                proposed: "Migration plan review"
            ) == "Pricing rework with Ana"
        )
    }

    @Test
    func aPlaceholderTitleIsReplacedByARealOne() {
        #expect(
            MeetingCoordinator.mergedTitle(
                existing: "Meeting Wed 2:03 PM",
                proposed: "Migration plan review"
            ) == "Migration plan review"
        )
        // Two placeholders leave the note as it was rather than swapping one
        // meaningless title for another.
        #expect(
            MeetingCoordinator.mergedTitle(
                existing: "Meeting Wed 2:03 PM",
                proposed: "Zoom meeting"
            ) == "Meeting Wed 2:03 PM"
        )
    }

    @Test
    func actionItemsAreJoinedRatherThanReplaced() {
        let merged = MeetingCoordinator.unionedActionItems(
            existing: [
                "Ana to send the migration plan [due: 2026-09-12]",
                "Book the load test window"
            ],
            proposed: [
                "ana to send the migration plan",
                "Draft the rollback note"
            ]
        )

        // The existing string is kept exactly, due suffix included, and the
        // reworded duplicate does not arrive alongside it.
        #expect(merged == [
            "Ana to send the migration plan [due: 2026-09-12]",
            "Book the load test window",
            "Draft the rollback note"
        ])
    }

    @Test
    func aTickedActionItemIsNotDuplicatedByItsUncheckedTwin() {
        let merged = MeetingCoordinator.unionedActionItems(
            existing: ["[x] Book the load test window"],
            proposed: ["Book the load test window"]
        )

        #expect(merged == ["[x] Book the load test window"])
    }

    @Test
    func backgroundEnrichmentPreservesEditsMadeAfterTheAppend() {
        let scaffold = summaryScaffold()
        var current = scaffold
        current.title = "Pricing rework with Ana"
        current.keyPoints = ["A point added while summarizing"]
        current.completedActionItems = ["Book the load test window"]
        current.personalNotes += "\n\nAnother thought"

        let merged = MeetingCoordinator.mergingAppendedSessionSummary(
            generatedSummary(),
            scaffold: scaffold,
            current: current
        )

        #expect(merged?.title == current.title)
        #expect(merged?.summary == "The migration plan was approved.")
        #expect(merged?.keyPoints == current.keyPoints)
        #expect(merged?.decisions == ["Proceed with migration"])
        #expect(merged?.actionItems == current.actionItems)
        #expect(merged?.completedActionItems == current.completedActionItems)
        #expect(merged?.personalNotes == current.personalNotes)
    }

    @Test
    func untouchedAppendedFieldsReceiveTheGroundedSummary() {
        let scaffold = summaryScaffold()
        let merged = MeetingCoordinator.mergingAppendedSessionSummary(
            generatedSummary(),
            scaffold: scaffold,
            current: scaffold
        )

        #expect(merged?.title == "Migration plan review")
        #expect(merged?.summary == "The migration plan was approved.")
        #expect(merged?.keyPoints == ["Migration is ready"])
        #expect(merged?.decisions == ["Proceed with migration"])
        #expect(merged?.actionItems == [
            "Book the load test window",
            "Draft the rollback note",
        ])
    }

    @Test
    func changedTranscriptRejectsAStaleAppendedSummary() {
        let scaffold = summaryScaffold()
        var current = scaffold
        current.transcript.append(
            TranscriptSegment(
                startTime: 14,
                duration: 3,
                text: "This arrived in a later sitting."
            )
        )

        #expect(
            MeetingCoordinator.mergingAppendedSessionSummary(
                generatedSummary(),
                scaffold: scaffold,
                current: current
            ) == current
        )
    }

    /// Audio kept under an earlier promise is never destroyed, and turning
    /// retention off means this sitting's audio is not kept, so it is not
    /// joined onto the note's file either.
    @Test
    func keptAudioFollowsTheRetentionSettingWithoutLosingWhatWasThere() {
        #expect(
            MeetingCoordinator.keptAudioPlan(
                keepAudio: true,
                priorAudioExists: true,
                priorAudioIsReadable: true
            ) == .concatenate
        )
        #expect(
            MeetingCoordinator.keptAudioPlan(
                keepAudio: false,
                priorAudioExists: true,
                priorAudioIsReadable: true
            ) == .keepPriorOnly
        )
        #expect(
            MeetingCoordinator.keptAudioPlan(
                keepAudio: true,
                priorAudioExists: false,
                priorAudioIsReadable: false
            ) == .adoptSession
        )
        #expect(
            MeetingCoordinator.keptAudioPlan(
                keepAudio: false,
                priorAudioExists: false,
                priorAudioIsReadable: false
            ) == .none
        )
    }

    /// A file that exists but cannot be measured used to be deleted outright.
    /// It is now moved aside by the adopting plan, and left alone entirely
    /// when nothing new is being kept.
    @Test
    func unreadablePriorAudioIsNeverSimplyDeleted() {
        #expect(
            MeetingCoordinator.keptAudioPlan(
                keepAudio: true,
                priorAudioExists: true,
                priorAudioIsReadable: false
            ) == .adoptSession
        )
        #expect(
            MeetingCoordinator.keptAudioPlan(
                keepAudio: false,
                priorAudioExists: true,
                priorAudioIsReadable: false
            ) == .keepPriorOnly
        )
    }
}

/// Any failure after the capture stopped discarded the live transcript, so a
/// Mac that could not close a file cost the user words Nook had already heard.
@MainActor
struct LiveCaptionRescueTests {
    private func note() -> MeetingNote {
        MeetingNote(
            id: UUID(),
            title: "Pricing rework with Ana",
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            endedAt: Date(timeIntervalSince1970: 1_001_800),
            sourceApp: "Manual",
            summary: "The team reviewed pricing.",
            transcript: [
                TranscriptSegment(
                    startTime: 0,
                    duration: 30,
                    text: "We reviewed the pricing tiers."
                )
            ]
        )
    }

    @Test
    func rescuedWordsJoinTheNoteAndSayWhereTheyCameFrom() {
        let rescued = MeetingCoordinator.appendingLiveCaptions(
            transcript: [
                TranscriptSegment(
                    startTime: 0,
                    duration: 20,
                    text: "The rollback plan needs a written owner."
                )
            ],
            moments: [MeetingMoment(offset: 5)],
            personalNotes: "Ask Ana about the tiers.",
            startedAt: Date(timeIntervalSince1970: 1_002_000),
            to: note()
        )

        #expect(rescued.transcript.count == 2)
        // The second sitting continues the timeline rather than overwriting it.
        #expect(rescued.transcript.last?.startTime ?? 0 >= 30)
        #expect(rescued.moments.map(\.offset) == [35])
        #expect(rescued.summary.contains("live captions"))
        #expect(rescued.personalNotes.contains("Ask Ana"))
        // The note keeps its own title and its earlier summary.
        #expect(rescued.title == "Pricing rework with Ana")
        #expect(rescued.summary.contains("The team reviewed pricing."))
    }

    /// A promise about the audio has to be true. The recording is kept, and
    /// the note says so, because that is the only way a better transcript is
    /// still reachable.
    @Test
    func theMarkerIsHonestAboutWhatHappened() {
        let marker = MeetingCoordinator.liveCaptionNoteMarker

        #expect(marker.contains("live captions"))
        #expect(marker.contains("recording was kept"))
        #expect(!marker.contains("\u{2014}"))
    }
}

/// Pausing removes the recording output before waiting for its file-close
/// callback. A missing callback must never be read as a failed removal: the
/// output was already detached, so no further audio reaches disk either way,
/// and resurrecting "recording" state leaves a phantom meeting that writes
/// nothing while its timer runs.
@MainActor
struct PauseRemovalErrorTests {
    @Test
    func aMissingCallbackDoesNotUndoThePause() {
        #expect(CaptureService.waitErrorMeansRemovalLanded(
            CaptureError.finalizationTimedOut
        ))
        #expect(CaptureService.waitErrorMeansRemovalLanded(
            CancellationError()
        ))
    }

    @Test
    func aFailedRemovalLeavesCaptureActive() {
        struct RemovalThrew: Error {}

        #expect(!CaptureService.waitErrorMeansRemovalLanded(
            CaptureError.notRecording
        ))
        #expect(!CaptureService.waitErrorMeansRemovalLanded(
            CaptureError.alreadyPaused
        ))
        #expect(!CaptureService.waitErrorMeansRemovalLanded(RemovalThrew()))
    }
}

/// Flagging marks an instant of the recording so it can be found later.
/// The offset math has to match the elapsed clock exactly, including pauses,
/// or a flag points at the wrong part of the conversation.
@MainActor
struct MomentFlaggingTests {
    private func moment(
        _ offset: TimeInterval
    ) -> MeetingMoment {
        MeetingMoment(offset: offset)
    }

    @Test
    func theOffsetMatchesThePausedElapsedClock() {
        // Five accumulated minutes, resumed twenty seconds ago. The clock is
        // derived, not sampled twice: two separate Date() calls drift apart
        // under suite load and the exact equality below fails on real time.
        let startedAt = Date(timeIntervalSince1970: 1_000)
        #expect(
            MeetingCoordinator.currentRecordingOffset(
                accumulated: 300,
                startedAt: startedAt,
                now: startedAt.addingTimeInterval(20)
            ) == 320
        )
        // Paused: no active start, so the flag freezes at the accumulation.
        #expect(
            MeetingCoordinator.currentRecordingOffset(
                accumulated: 300,
                startedAt: nil,
                now: startedAt
            ) == 300
        )
    }

    @Test
    func doublePressesInsideASecondAreIgnored() {
        let flagged = [
            moment(10), moment(10.4), moment(11.9), moment(60)
        ]

        var moments: [MeetingMoment] = []
        for candidate in flagged {
            moments = MeetingCoordinator.appendingMoment(
                moments,
                at: candidate.offset
            )
        }

        // 10.4 is a double-press; 11.9 and 60 are deliberate flags.
        #expect(moments.map(\.offset) == [10, 11.9, 60])
    }
}
