import AVFoundation
import CoreMedia
import Foundation
import Speech

actor TranscriptionService {
    func transcribe(audioURL: URL, localeIdentifier: String) async throws -> [TranscriptSegment] {
        try await SpeechAssets.requestAuthorization()
        let supportedLocale = try await SpeechAssets.supportedLocale(for: localeIdentifier)

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

        let audioFile = try AVAudioFile(forReading: audioURL)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let resultsTask = Task<[TranscriptSegment], Error> {
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results {
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

        do {
            let finalTime = try await analyzer.analyzeSequence(from: audioFile)
            try await analyzer.finalize(through: finalTime)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await resultsTask.value.sorted { $0.startTime < $1.startTime }
        } catch {
            resultsTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

}

enum TranscriptionError: LocalizedError {
    case permissionDenied
    case unsupportedLocale(String)
    case assetsUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Speech Recognition permission is required for local transcription."
        case .unsupportedLocale(let locale):
            "On-device transcription is not available for \(locale)."
        case .assetsUnavailable:
            "The on-device speech model is not available. Connect once so macOS can install the language asset."
        }
    }
}
