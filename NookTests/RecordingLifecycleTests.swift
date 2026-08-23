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
    /// re-transcription of a meeting whose recognizer stayed healthy.
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
