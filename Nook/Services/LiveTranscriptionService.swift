import AVFoundation
import CoreMedia
import Foundation
import Speech

struct LiveTranscriptState: Equatable, Sendable {
    var segments: [TranscriptSegment] = []
    var meetingPartial = ""
    var microphonePartial = ""
    var latestSource: TranscriptSegment.Source = .system
    var revision = 0

    static let empty = LiveTranscriptState()

    var latestText: String {
        let partial = latestSource == .microphone ? microphonePartial : meetingPartial
        if !partial.isEmpty { return partial }
        return segments.last?.text ?? ""
    }

    var recentSegments: [TranscriptSegment] {
        Array(segments.suffix(8))
    }

    var notchCaptionLines: [LiveCaptionLine] {
        let partial = activePartial
        let finalizedLimit = partial == nil ? 5 : 3
        var lines = segments.suffix(finalizedLimit).map {
            LiveCaptionLine(
                id: .segment($0.id),
                source: $0.source,
                text: $0.text,
                isPartial: false
            )
        }

        if let partial {
            lines.append(
                LiveCaptionLine(
                    id: .partial(partial.source),
                    source: partial.source,
                    text: partial.text,
                    isPartial: true
                )
            )
        }
        return lines
    }

    var wordCount: Int {
        segments.reduce(0) { count, segment in
            count + segment.text.split(whereSeparator: \.isWhitespace).count
        }
    }

    private var activePartial: (source: TranscriptSegment.Source, text: String)? {
        let preferred = latestSource == .microphone
            ? microphonePartial
            : meetingPartial
        if !preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (latestSource, preferred)
        }

        let alternateSource: TranscriptSegment.Source = latestSource == .microphone
            ? .system
            : .microphone
        let alternate = alternateSource == .microphone
            ? microphonePartial
            : meetingPartial
        guard !alternate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return (alternateSource, alternate)
    }
}

struct LiveCaptionLine: Identifiable, Equatable, Sendable {
    enum ID: Hashable, Sendable {
        case segment(UUID)
        case partial(TranscriptSegment.Source)
    }

    let id: ID
    let source: TranscriptSegment.Source
    let text: String
    let isPartial: Bool
}

@MainActor
final class LiveTranscriptionService {
    var onUpdate: ((LiveTranscriptState) -> Void)?
    var onRecoverableError: ((String) -> Void)?

    private var tracks: [TranscriptSegment.Source: LiveTrack] = [:]
    private var trackStates: [TranscriptSegment.Source: TrackSnapshot] = [:]
    private(set) var isRunning = false

    func start(localeIdentifier: String) async throws {
        guard !isRunning else { return }
        try await SpeechAssets.requestAuthorization()
        let locale = try await SpeechAssets.supportedLocale(for: localeIdentifier)

        let meetingTranscriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedProgressiveTranscription
        )
        let microphoneTranscriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedProgressiveTranscription
        )
        try await SpeechAssets.installIfNeeded(
            for: [meetingTranscriber, microphoneTranscriber],
            locale: locale
        )
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [meetingTranscriber, microphoneTranscriber]
        ) else {
            throw TranscriptionError.assetsUnavailable
        }

        let meetingTrack = LiveTrack(
            source: .system,
            transcriber: meetingTranscriber,
            analyzerFormat: analyzerFormat
        )
        let microphoneTrack = LiveTrack(
            source: .microphone,
            transcriber: microphoneTranscriber,
            analyzerFormat: analyzerFormat
        )
        meetingTrack.onUpdate = { [weak self] snapshot in
            self?.receive(snapshot)
        }
        microphoneTrack.onUpdate = { [weak self] snapshot in
            self?.receive(snapshot)
        }
        meetingTrack.onError = { [weak self] message in
            self?.onRecoverableError?(message)
        }
        microphoneTrack.onError = { [weak self] message in
            self?.onRecoverableError?(message)
        }

        tracks = [.system: meetingTrack, .microphone: microphoneTrack]
        trackStates = [
            .system: TrackSnapshot(source: .system),
            .microphone: TrackSnapshot(source: .microphone)
        ]
        isRunning = true
        meetingTrack.start()
        microphoneTrack.start()
        publish()
    }

    func ingest(
        _ buffer: AVAudioPCMBuffer,
        source: TranscriptSegment.Source
    ) {
        guard isRunning else { return }
        tracks[source]?.ingest(buffer)
    }

    func stop() async -> [TranscriptSegment] {
        guard isRunning else { return mergedSegments() }
        isRunning = false

        // Each track's analyzer is already running in its own task. Awaiting the
        // two finishes serially avoids crossing actor regions while both streams
        // still drain concurrently.
        for track in tracks.values {
            await track.finish()
        }
        let result = TranscriptAssembler.coalesce(
            deduplicated(mergedSegments())
        )
        tracks.removeAll()
        publish()
        return result
    }

    func cancel() async {
        isRunning = false
        for track in tracks.values {
            await track.cancel()
        }
        tracks.removeAll()
        trackStates.removeAll()
        publish()
    }

    private func receive(_ snapshot: TrackSnapshot) {
        trackStates[snapshot.source] = snapshot
        publish()
    }

    private func publish() {
        let meeting = trackStates[.system] ?? TrackSnapshot(source: .system)
        let microphone = trackStates[.microphone] ?? TrackSnapshot(source: .microphone)
        let newest = [meeting, microphone].max { lhs, rhs in
            lhs.lastChangedAt < rhs.lastChangedAt
        }

        var state = LiveTranscriptState(
            segments: TranscriptAssembler.coalesce(
                deduplicated(mergedSegments())
            ),
            meetingPartial: meeting.partial,
            microphonePartial: microphone.partial,
            latestSource: newest?.source ?? .system,
            revision: meeting.revision + microphone.revision
        )
        if state.latestSource == .system, state.meetingPartial.isEmpty,
           !state.microphonePartial.isEmpty {
            state.latestSource = .microphone
        }
        onUpdate?(state)
    }

    private func mergedSegments() -> [TranscriptSegment] {
        trackStates.values
            .flatMap(\.segments)
            .sorted {
                if abs($0.startTime - $1.startTime) < 0.08 {
                    return $0.source == .microphone
                }
                return $0.startTime < $1.startTime
            }
    }

    private func deduplicated(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for segment in segments {
            let duplicateIndex = result.lastIndex { existing in
                abs(existing.startTime - segment.startTime) < 4
                    && similarity(existing.text, segment.text) > 0.72
            }
            if let duplicateIndex {
                if result[duplicateIndex].source == .microphone, segment.source == .system {
                    result[duplicateIndex] = segment
                }
            } else {
                result.append(segment)
            }
        }
        return result.sorted { $0.startTime < $1.startTime }
    }

    private func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Set(lhs.lowercased().split { !$0.isLetter && !$0.isNumber })
        let right = Set(rhs.lowercased().split { !$0.isLetter && !$0.isNumber })
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let overlap = left.intersection(right).count
        return Double(overlap) / Double(max(left.count, right.count))
    }
}

private struct TrackSnapshot: Sendable {
    let source: TranscriptSegment.Source
    var segments: [TranscriptSegment] = []
    var partial = ""
    var revision = 0
    var lastChangedAt = Date.distantPast
}

@MainActor
private final class LiveTrack {
    let source: TranscriptSegment.Source
    var onUpdate: ((TrackSnapshot) -> Void)?
    var onError: ((String) -> Void)?

    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let stream: AsyncStream<AnalyzerInput>
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let inputConverter: any LiveAnalyzerInputConverting
    private var analysisTask: Task<CMTime?, Error>?
    private var resultsTask: Task<Void, Never>?
    private var snapshot: TrackSnapshot
    private var reportedConversionFailure = false
    private var didReceiveInput = false

    /// Finalizing a long meeting legitimately takes a few seconds. Beyond this
    /// the transcript is treated as unavailable and Nook refines from the saved
    /// audio instead of holding the meeting in processing forever.
    private static let finalizationTimeout: Double = 8

    init(
        source: TranscriptSegment.Source,
        transcriber: SpeechTranscriber,
        analyzerFormat: AVAudioFormat
    ) {
        self.source = source
        self.transcriber = transcriber
        self.analyzer = SpeechAnalyzer(modules: [transcriber])
        self.inputConverter = makeLiveInputConverter(
            analyzerFormat: analyzerFormat
        )
        let pair = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(180)
        )
        self.stream = pair.stream
        self.continuation = pair.continuation
        self.snapshot = TrackSnapshot(source: source)
    }

    func start() {
        analysisTask = Task {
            try await analyzer.analyzeSequence(stream)
        }
        let transcriber = self.transcriber
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { return }
                    self?.accept(result)
                }
            } catch {
                self?.onError?("Live \(self?.source.label.lowercased() ?? "speech") captions paused. The final recording is safe.")
            }
        }
    }

    func ingest(_ buffer: AVAudioPCMBuffer) {
        do {
            for input in try inputConverter.convert(buffer) {
                continuation.yield(input)
                didReceiveInput = true
            }
        } catch {
            guard !reportedConversionFailure else { return }
            reportedConversionFailure = true
            onError?(
                "Live \(source.label.lowercased()) captions paused. "
                    + "The final recording is safe."
            )
        }
    }

    func finish() async {
        // An analyzer that never received a buffer has no session to finalize,
        // and asking it to finalize anyway never returns. This is the state a
        // failed input conversion leaves behind, so it must not block the
        // meeting from reaching the saved-audio fallback.
        guard didReceiveInput else {
            abandon()
            return
        }

        if !reportedConversionFailure {
            do {
                for input in try inputConverter.flush() {
                    continuation.yield(input)
                }
            } catch {
                onError?("Nook will refine this transcript from the saved audio.")
            }
        }
        continuation.finish()

        let finished = await withDeadline(
            seconds: Self.finalizationTimeout
        ) { [weak self] in
            guard let self else { return }
            do {
                let finalTime = try await self.analysisTask?.value
                try await self.analyzer.finalize(through: finalTime ?? nil)
                try await self.analyzer.finalizeAndFinishThroughEndOfInput()
                await self.resultsTask?.value
            } catch {
                self.onError?(
                    "Nook will refine this transcript from the saved audio."
                )
                await self.analyzer.cancelAndFinishNow()
                self.resultsTask?.cancel()
            }
        }

        guard !finished else { return }
        onError?("Nook will refine this transcript from the saved audio.")
        abandon()
    }

    /// Cancelling discards this track's results, so there is nothing to wait
    /// for — and waiting is what previously let a stalled analyzer wedge the
    /// recovery paths that call this.
    func cancel() async {
        abandon()
    }

    /// Tears the track down without waiting on the Speech framework. The
    /// analyzer is released on its own task because `cancelAndFinishNow()` can
    /// itself stall, and by this point nothing is waiting for its result.
    private func abandon() {
        continuation.finish()
        analysisTask?.cancel()
        resultsTask?.cancel()
        let analyzer = self.analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }

    private func accept(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let start = max(0, result.range.start.seconds)
        if result.isFinal {
            let segment = TranscriptSegment(
                startTime: start,
                duration: max(0, result.range.duration.seconds),
                text: text,
                source: source
            )
            if snapshot.segments.last?.text != text {
                snapshot.segments.append(segment)
            }
            snapshot.partial = ""
        } else {
            snapshot.partial = text
        }
        snapshot.revision += 1
        snapshot.lastChangedAt = Date()
        onUpdate?(snapshot)
    }
}

/// Runs `operation` with a deadline and reports whether it finished in time.
///
/// A task group is deliberately not used: it awaits every child before
/// returning, so a stalled operation would still block the caller — which is
/// exactly the failure this guards against. The losing task is abandoned.
@MainActor
private func withDeadline(
    seconds: Double,
    operation: @escaping @MainActor () async -> Void
) async -> Bool {
    let signal = DeadlineSignal()
    let work = Task { @MainActor in
        await operation()
        signal.signal(true)
    }
    let timer = Task { @MainActor in
        try? await Task.sleep(for: .seconds(seconds))
        guard !Task.isCancelled else { return }
        signal.signal(false)
    }

    let finished = await signal.wait()
    timer.cancel()
    if !finished {
        work.cancel()
    }
    return finished
}

/// A one-shot main-actor signal that tolerates being resolved before or after
/// the waiter arrives.
@MainActor
private final class DeadlineSignal {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var resolved: Bool?

    func wait() async -> Bool {
        if let resolved { return resolved }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func signal(_ value: Bool) {
        guard resolved == nil else { return }
        resolved = value
        continuation?.resume(returning: value)
        continuation = nil
    }
}

protocol LiveAnalyzerInputConverting: AnyObject {
    func convert(_ buffer: AVAudioPCMBuffer) throws -> [AnalyzerInput]
    func flush() throws -> [AnalyzerInput]
}

/// ScreenCaptureKit delivers 48 kHz stereo; `SpeechAnalyzer` asks for its own
/// (typically 16 kHz mono) format, so capture buffers essentially never match
/// it. `AVAudioConverter` bridges the two on every supported system.
///
/// This deliberately does not use `AnalyzerInputConverter`. That type only
/// exists in the macOS 27 SDK, so referencing it makes live transcription
/// depend on which Xcode built the app — releases compiled with the stable
/// toolchain silently lost the conversion path and produced no live captions
/// at all. `AVAudioConverter` keeps runtime behavior independent of the
/// build toolchain.
final class ResamplingAnalyzerInputConverter: LiveAnalyzerInputConverting {
    private let analyzerFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    init(analyzerFormat: AVAudioFormat) {
        self.analyzerFormat = analyzerFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> [AnalyzerInput] {
        try convertToBuffers(buffer).map { AnalyzerInput(buffer: $0) }
    }

    func flush() throws -> [AnalyzerInput] {
        try flushBuffers().map { AnalyzerInput(buffer: $0) }
    }

    /// The buffer-level entry points keep the resampling behavior verifiable
    /// without constructing Speech framework input values in tests.
    func convertToBuffers(
        _ buffer: AVAudioPCMBuffer
    ) throws -> [AVAudioPCMBuffer] {
        guard buffer.frameLength > 0 else { return [] }
        if buffer.format == analyzerFormat {
            return [buffer]
        }

        let converter = try converter(for: buffer.format)
        // Sample-rate conversion is stateful, so the resampler can emit more
        // frames than a naive ratio suggests. The padding keeps a full input
        // buffer from being truncated.
        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * ratio).rounded(.up)
        ) + 1024

        guard let output = try drain(
            converter: converter,
            capacity: capacity,
            provide: { buffer },
            whenStarved: .noDataNow
        ) else {
            return []
        }
        return [output]
    }

    func flushBuffers() throws -> [AVAudioPCMBuffer] {
        guard let converter else { return [] }
        // One second of headroom comfortably covers any resampler tail.
        let capacity = AVAudioFrameCount(analyzerFormat.sampleRate)
        guard let output = try drain(
            converter: converter,
            capacity: capacity,
            provide: { nil },
            whenStarved: .endOfStream
        ) else {
            return []
        }
        return [output]
    }

    private func converter(
        for format: AVAudioFormat
    ) throws -> AVAudioConverter {
        if let converter, sourceFormat == format {
            return converter
        }
        guard let created = AVAudioConverter(
            from: format,
            to: analyzerFormat
        ) else {
            throw LiveInputConversionError.unsupportedFormat
        }
        converter = created
        sourceFormat = format
        return created
    }

    /// Pulls one output buffer out of `converter`. `provide` returns the source
    /// buffer once, after which `whenStarved` reports why no more is coming.
    ///
    /// Live conversion must starve with `.noDataNow`: `.endOfStream` moves the
    /// converter into a terminal state and every later buffer in the meeting
    /// would silently yield nothing. Only `flush()` ends the stream.
    private func drain(
        converter: AVAudioConverter,
        capacity: AVAudioFrameCount,
        provide: @escaping () -> AVAudioPCMBuffer?,
        whenStarved: AVAudioConverterInputStatus
    ) throws -> AVAudioPCMBuffer? {
        guard let output = AVAudioPCMBuffer(
            pcmFormat: analyzerFormat,
            frameCapacity: capacity
        ) else {
            throw LiveInputConversionError.unsupportedFormat
        }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(
            to: output,
            error: &conversionError
        ) { _, inputStatus in
            guard !supplied, let buffer = provide() else {
                inputStatus.pointee = whenStarved
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            // `inputRanDry` and `endOfStream` are the normal terminal states
            // once the single supplied buffer has been consumed.
            return output.frameLength > 0 ? output : nil
        case .error:
            throw conversionError ?? LiveInputConversionError.unsupportedFormat
        @unknown default:
            throw LiveInputConversionError.unsupportedFormat
        }
    }
}

func makeLiveInputConverter(
    analyzerFormat: AVAudioFormat
) -> any LiveAnalyzerInputConverting {
    ResamplingAnalyzerInputConverter(analyzerFormat: analyzerFormat)
}

enum LiveInputConversionError: Error {
    case unsupportedFormat
}

extension TranscriptSegment.Source {
    var label: String {
        switch self {
        case .microphone: "You"
        case .system: "Meeting"
        case .mixed: "Meeting"
        }
    }

    var symbol: String {
        switch self {
        case .microphone: "person.crop.circle.fill"
        case .system, .mixed: "quote.bubble.fill"
        }
    }
}
