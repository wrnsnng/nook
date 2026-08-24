import Foundation
import Testing
@testable import Nook

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

/// Summarizing had no deadline at all, so a wedged on-device model held the
/// save, and therefore a quit, open indefinitely.
@MainActor
struct SummaryDeadlineTests {
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

/// Recording into a note regenerated its title and replaced its action items,
/// so a name the user chose and a commitment they were still tracking both
/// disappeared because a second sitting did not mention them again.
@MainActor
struct AppendedSessionTests {
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
