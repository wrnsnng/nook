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
}
