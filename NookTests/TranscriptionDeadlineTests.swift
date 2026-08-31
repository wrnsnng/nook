import Foundation
import Synchronization
import Testing
@testable import Nook

/// A saved recording must remain recoverable when Speech never finishes.
/// These injected operations neither request permission nor read real audio.
struct TranscriptionDeadlineTests {
    private let audioURL = URL(fileURLWithPath: "/synthetic/recording.m4a")

    @Test
    func completedSpeechReturnsWithoutAlteringItsWords() async throws {
        let spoken = [TranscriptSegment(startTime: 0, duration: 2, text: "Keep these words.")]
        let service = TranscriptionService(operation: { _, _ in spoken }, timeout: 10)
        #expect(try await service.transcribe(audioURL: audioURL, localeIdentifier: "en_US") == spoken)
    }

    @Test
    func speechFailuresKeepTheirOriginalExplanation() async {
        let service = TranscriptionService(operation: { _, _ in
            throw TranscriptionError.assetsUnavailable
        }, timeout: 10)
        await #expect(throws: TranscriptionError.assetsUnavailable) {
            try await service.transcribe(audioURL: audioURL, localeIdentifier: "en_US")
        }
    }

    @Test
    func aStalledSpeechOperationDoesNotHoldItsCallerPastTheDeadline() async {
        let speech = SuspendedSavedSpeech()
        let service = TranscriptionService(operation: { _, _ in
            await speech.result()
        }, timeout: 0.02)
        await #expect(throws: TranscriptionError.timedOut) {
            try await service.transcribe(audioURL: audioURL, localeIdentifier: "en_US")
        }
        // The caller returned while Speech still refused to finish. Releasing
        // it afterwards must not turn that refusal into a late successful save.
        #expect(await !speech.finished)
        await speech.finish()
    }

    @Test
    func cancellingProcessingDoesNotWaitForUncooperativeSpeech() async {
        let speech = SuspendedSavedSpeech()
        let service = TranscriptionService(operation: { _, _ in
            await speech.result()
        }, timeout: 3_600)
        let request = Task {
            try await service.transcribe(audioURL: audioURL, localeIdentifier: "en_US")
        }
        await speech.waitUntilStarted()
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(await !speech.finished)
        await speech.finish()
    }

    @Test
    func aDeadlineCancelsTheUnderlyingSpeechWorkOnce() async {
        let speech = SuspendedSavedSpeech()
        let cancellations = Mutex(0)
        let service = TranscriptionService(operation: { _, _ in
            await withTaskCancellationHandler {
                await speech.result()
            } onCancel: {
                cancellations.withLock { $0 += 1 }
            }
        }, timeout: 0.02)
        let request = Task {
            try await service.transcribe(audioURL: audioURL, localeIdentifier: "en_US")
        }
        await speech.waitUntilStarted()
        await #expect(throws: TranscriptionError.timedOut) { try await request.value }
        #expect(cancellations.withLock { $0 } == 1)
        await speech.finish()
    }

    @Test
    func aRequestCancelledBeforeEntryNeverStartsSpeech() async {
        let gate = SuspendedSavedSpeech()
        let calls = Mutex(0)
        let service = TranscriptionService(operation: { _, _ in
            calls.withLock { $0 += 1 }
            return []
        }, timeout: 10)
        let request = Task {
            _ = await gate.result()
            return try await service.transcribe(audioURL: audioURL, localeIdentifier: "en_US")
        }
        await gate.waitUntilStarted()
        request.cancel()
        await gate.finish()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(calls.withLock { $0 } == 0)
    }

    @Test
    func longerRecordingsGetMoreTimeButNeverAnUnboundedWait() {
        #expect(TranscriptionService.deadline(for: 0) == 120)
        #expect(TranscriptionService.deadline(for: 600) == 720)
        #expect(TranscriptionService.deadline(for: 10_000) == 3_600)
        #expect(TranscriptionService.deadline(for: -.infinity) == 120)
        #expect(TranscriptionService.deadline(for: .nan) == 120)
    }
}

private actor SuspendedSavedSpeech {
    private var continuation: CheckedContinuation<[TranscriptSegment], Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var didStart = false
    private(set) var finished = false

    func result() async -> [TranscriptSegment] {
        didStart = true
        started?.resume()
        started = nil
        guard !finished else { return [] }
        // Intentionally ignores task cancellation, like a stalled SDK call.
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish() {
        finished = true
        continuation?.resume(returning: [])
        continuation = nil
    }
}
