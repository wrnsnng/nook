import AVFoundation
import CoreMedia
import Foundation
import Speech
import Synchronization

actor TranscriptionService {
    typealias Operation = @Sendable (URL, String) async throws -> [TranscriptSegment]

    private let operation: Operation
    private let timeoutOverride: TimeInterval?

    init(operation: Operation? = nil, timeout: TimeInterval? = nil) {
        self.operation = operation ?? { url, locale in
            try await Self.transcribeFile(audioURL: url, localeIdentifier: locale)
        }
        self.timeoutOverride = timeout
    }

    func transcribe(
        audioURL: URL, recordingURLs: [URL] = [], localeIdentifier: String
    ) async throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        let seconds = timeoutOverride ?? Self.deadline(for: Self.duration(of: audioURL))
        let operation = operation
        let work = Task {
            let selection = try SourceAudioFiles.select(recordingURLs)
            if let sourced = try await RecordedSourceTranscription.transcribeIfLabelled(
                recordingURLs: selection.urls, localeIdentifier: localeIdentifier, operation: operation
            ) {
                try selection.validate()
                return sourced
            }
            try Task.checkCancellation()
            let playbackSnapshot = recordingURLs.isEmpty ? nil : try NoteCombiner.AudioFileSnapshot(url: audioURL)
            let result = try await operation(audioURL, localeIdentifier)
            try Task.checkCancellation()
            do {
                try selection.validate()
                try playbackSnapshot?.validate()
            } catch { throw AudioExtractionError.filesChanged }
            return result
        }
        // A Speech sequence or its finalization can stop yielding forever.
        // The same abandoning deadline as live capture lets the caller retain
        // its recording and show recovery instead of awaiting a stuck child.
        let result = await withDeadline(seconds: seconds) { await work.result }
        guard let result else {
            work.cancel()
            try Task.checkCancellation()
            throw TranscriptionError.timedOut
        }
        try Task.checkCancellation()
        return try result.get()
    }

    /// Give long recordings more time without letting an unresponsive SDK
    /// hold processing forever. This is a safety ceiling, not a speed target.
    static func deadline(for audioDuration: TimeInterval) -> TimeInterval {
        let duration = audioDuration.isFinite ? max(0, audioDuration) : 0
        return min(3_600, 120 + duration)
    }

    private static func duration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url),
              file.processingFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private static func transcribeFile(
        audioURL: URL,
        localeIdentifier: String
    ) async throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        try await SpeechAssets.requestAuthorization()
        try Task.checkCancellation()
        let supportedLocale = try await SpeechAssets.supportedLocale(for: localeIdentifier)
        try Task.checkCancellation()

        // Deliberately the same preset the live path uses. This pass only reads
        // `text`, `range`, and `isFinal`, so the alternatives preset added no
        // information — but its assets are frequently not installed and cannot
        // be requested (`assetInstallationRequest` returns nil), which made the
        // saved-audio recovery path fail with "the on-device speech model is
        // not available" exactly when it was needed most.
        let transcriber = SpeechTranscriber(
            locale: supportedLocale,
            preset: .timeIndexedProgressiveTranscription
        )
        try await SpeechAssets.installIfNeeded(for: [transcriber], locale: supportedLocale)
        try Task.checkCancellation()

        let audioFile = try AVAudioFile(forReading: audioURL)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let resultsTask = Task<[TranscriptSegment], Error> {
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results {
                try Task.checkCancellation()
                guard result.isFinal else { continue }
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                segments.append(
                    TranscriptSegment(
                        startTime: result.range.start.seconds,
                        duration: result.range.duration.seconds,
                        text: text
                    )
                )
            }
            return segments
        }

        let cleanupStarted = Mutex(false)
        let cancelAnalysis: @Sendable () -> Void = {
            let shouldStart = cleanupStarted.withLock { started in
                guard !started else { return false }
                started = true
                return true
            }
            guard shouldStart else { return }
            resultsTask.cancel()
            // Cleanup is best effort. Waiting for a second stalled framework
            // call here would undo the deadline above and delay cancellation.
            Task { await analyzer.cancelAndFinishNow() }
        }

        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let finalTime = try await analyzer.analyzeSequence(from: audioFile)
                try Task.checkCancellation()
                try await analyzer.finalize(through: finalTime)
                try Task.checkCancellation()
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                try Task.checkCancellation()
                return try await resultsTask.value.sorted { $0.startTime < $1.startTime }
            } catch {
                cancelAnalysis()
                throw error
            }
        } onCancel: {
            // A catch alone is insufficient: a stuck analyze/finalize call
            // never throws. Stop its result consumer as soon as the caller
            // leaves, and request analyzer cleanup exactly once.
            cancelAnalysis()
        }
    }

}

enum TranscriptionError: LocalizedError, Equatable {
    case permissionDenied
    case unsupportedLocale(String)
    case assetsUnavailable
    case timedOut

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Speech Recognition permission is required for local transcription."
        case .unsupportedLocale(let locale):
            "On-device transcription is not available for \(locale)."
        case .assetsUnavailable:
            "The on-device speech model is not available. Connect once so macOS can install the language asset."
        case .timedOut:
            "Local transcription took too long. Try recovering the recording again."
        }
    }
}
