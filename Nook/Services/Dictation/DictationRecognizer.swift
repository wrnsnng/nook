import AVFoundation
import CoreMedia
import Foundation
import Speech

@MainActor
protocol DictationRecognizing: AnyObject {
    var onVolatile: (@MainActor (String) -> Void)? { get set }
    var onFinalized: (@MainActor (String) -> Void)? { get set }
    var onError: (@MainActor (String) -> Void)? { get set }
    /// The recognizer stopped on its own, without an error and without being
    /// asked to. Everything already finalized still stands.
    var onEnded: (@MainActor () -> Void)? { get set }
    func start(localeIdentifier: String) async throws
    func ingest(_ buffer: AVAudioPCMBuffer)
    func finish() async
    func cancel()
}

/// Turns microphone audio into dictated text.
///
/// The split between volatile and finalized output is the whole point of this
/// type. Apple's recognizer continuously revises what it thinks it heard —
/// "I want to buy" becomes "I want to write" a moment later — and only marks a
/// span final once it has stopped changing. Volatile text is safe to show in
/// Nook's own indicator, where a rewrite costs nothing. Only finalized text is
/// safe to put in someone's document, where a rewrite means deleting
/// characters they are watching.
@MainActor
final class DictationRecognizer: DictationRecognizing {
    /// The current in-progress guess. Replaces whatever was sent before.
    var onVolatile: (@MainActor (String) -> Void)?
    /// A span that will not change again. Append-only.
    var onFinalized: (@MainActor (String) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    var onEnded: (@MainActor () -> Void)?

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var inputConverter: (any LiveAnalyzerInputConverting)?
    private var analysisTask: Task<CMTime?, Error>?
    private var resultsTask: Task<Void, Never>?
    private var didReceiveInput = false
    private var reportedConversionFailure = false
    private var lastFinalizedStart: CMTime?
    /// Set while `finish()` is draining, so the results stream ending is read
    /// as the expected end of a flush rather than as the recognizer stopping.
    private var isFinishing = false
    /// Where an asset installation failure is parked, because the deadline
    /// below can only carry a value across, not a thrown error.
    private var assetInstallFailure: (any Error)?

    /// Dictation is interactive: nobody will wait eight seconds to find out
    /// their sentence is not coming. Past this, whatever was already finalized
    /// is used and the rest is dropped.
    private static let finalizationTimeout: Double = 3

    /// A first dictation in a language downloads a speech asset, and that
    /// download has no deadline of its own. Matches the ceiling the already
    /// downloading branch of `SpeechAssets` uses, so the two cannot disagree
    /// about how long is too long.
    private static let assetInstallTimeout: Double = 60

    func start(localeIdentifier: String) async throws {
        // Asset installation and authorization can take seconds, during which
        // a second start would otherwise overwrite a live session's handles and
        // leave the first one running with nothing able to stop it.
        if analyzer != nil { cancel() }
        lastFinalizedStart = nil
        isFinishing = false

        try await SpeechAssets.requestAuthorization()
        let locale = try await SpeechAssets.supportedLocale(for: localeIdentifier)

        // The same preset the meeting paths use. Its assets are the ones macOS
        // actually installs; the alternatives preset reports itself supported
        // and then refuses to provide an installation request.
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedProgressiveTranscription
        )
        // Bounded, because the microphone is already the user's to lose. An
        // install that never finishes, on a metered or unreachable network,
        // would otherwise leave the shortcut looking pressed forever.
        assetInstallFailure = nil
        let installed: Void? = await withDeadline(
            seconds: Self.assetInstallTimeout
        ) { [weak self, transcriber, locale] () -> Void in
            do {
                try await SpeechAssets.installIfNeeded(
                    for: [transcriber],
                    locale: locale
                )
            } catch {
                self?.assetInstallFailure = error
            }
        }
        guard installed != nil else {
            throw SpeechAssetError.installTimedOut
        }
        if let failure = assetInstallFailure {
            assetInstallFailure = nil
            throw failure
        }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            throw TranscriptionError.assetsUnavailable
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let pair = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(180)
        )

        self.transcriber = transcriber
        self.analyzer = analyzer
        self.continuation = pair.continuation
        self.inputConverter = makeLiveInputConverter(
            analyzerFormat: analyzerFormat
        )
        self.didReceiveInput = false
        self.reportedConversionFailure = false

        analysisTask = Task {
            try await analyzer.analyzeSequence(pair.stream)
        }
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { return }
                    self?.accept(result)
                }
                // A sequence that ends cleanly while the run is still live is a
                // recognizer that stopped without an error: no throw, no
                // callback, and no more words however long the user keeps
                // talking. Nothing else would notice, and in hold-to-talk the
                // microphone would stay open until the key came back up.
                // Ending the run here delivers what was actually heard.
                guard let self, !self.isFinishing, !Task.isCancelled else {
                    return
                }
                self.onEnded?()
            } catch {
                self?.onError?("Dictation stopped hearing your microphone.")
            }
        }
    }

    func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let inputConverter, let continuation else { return }
        do {
            for input in try inputConverter.convert(buffer) {
                continuation.yield(input)
                didReceiveInput = true
            }
        } catch {
            guard !reportedConversionFailure else { return }
            reportedConversionFailure = true
            onError?("Nook couldn’t read audio from that microphone.")
        }
    }

    /// Flushes the recognizer and returns once every remaining finalized span
    /// has been delivered through `onFinalized`.
    func finish() async {
        isFinishing = true
        guard didReceiveInput else {
            cancel()
            return
        }

        if !reportedConversionFailure, let inputConverter, let continuation {
            for input in (try? inputConverter.flush()) ?? [] {
                continuation.yield(input)
            }
        }
        continuation?.finish()

        let finished: Void? = await withDeadline(
            seconds: Self.finalizationTimeout
        ) { [weak self] () -> Void in
            guard let self, let analyzer = self.analyzer else { return }
            do {
                let finalTime = try await self.analysisTask?.value
                try await analyzer.finalize(through: finalTime ?? nil)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                await self.resultsTask?.value
            } catch {
                await analyzer.cancelAndFinishNow()
                self.resultsTask?.cancel()
            }
        }

        if finished == nil {
            // Whatever was already finalized has been inserted; the tail is
            // lost rather than left holding the user's keyboard.
            cancel()
            return
        }
        clear()
    }

    /// Drops the session without waiting on the Speech framework.
    func cancel() {
        // Set before the stream is torn down: the results task ending because
        // of this is not the recognizer stopping on its own.
        isFinishing = true
        continuation?.finish()
        analysisTask?.cancel()
        resultsTask?.cancel()
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        clear()
    }

    private func clear() {
        continuation = nil
        analysisTask = nil
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        inputConverter = nil
    }

    private func accept(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        guard result.isFinal else {
            onVolatile?(text)
            return
        }

        // The Speech framework can repeat a final result for the same span.
        // `LiveTrack` already defends against this when building a transcript;
        // here the cost is higher, because the words have already been typed
        // into the user's document and a repeat would duplicate them on screen.
        //
        // Deliberately keyed on the span's start time rather than the text.
        // Comparing text would also swallow a genuine repetition — someone
        // saying "No. No." means both, and they arrive as two spans at two
        // different times. Only a re-emission of the same span is a duplicate.
        guard result.range.start != lastFinalizedStart else { return }
        lastFinalizedStart = result.range.start
        onVolatile?("")
        onFinalized?(text)
    }
}
