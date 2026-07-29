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
        do {
            let finalTime = try await analysisTask?.value
            try await analyzer.finalize(through: finalTime ?? nil)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            await resultsTask?.value
        } catch {
            onError?("Nook will refine this transcript from the saved audio.")
            await analyzer.cancelAndFinishNow()
            resultsTask?.cancel()
        }
    }

    func cancel() async {
        continuation.finish()
        analysisTask?.cancel()
        resultsTask?.cancel()
        await analyzer.cancelAndFinishNow()
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

private protocol LiveAnalyzerInputConverting: AnyObject {
    func convert(_ buffer: AVAudioPCMBuffer) throws -> [AnalyzerInput]
    func flush() throws -> [AnalyzerInput]
}

@available(macOS 27.0, *)
private final class NativeLiveAnalyzerInputConverter:
    LiveAnalyzerInputConverting
{
    private let converter: AnalyzerInputConverter

    init(analyzerFormat: AVAudioFormat) {
        converter = AnalyzerInputConverter(analyzerFormat: analyzerFormat)
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> [AnalyzerInput] {
        try converter.convert(buffer, at: nil)
    }

    func flush() throws -> [AnalyzerInput] {
        try converter.flush()
    }
}

/// macOS 26 does not expose `AnalyzerInputConverter`. Exact-format buffers can
/// still be passed through safely; other formats fall back to the saved-audio
/// transcription instead of invoking `AnalyzerInput` with unsupported data.
private final class CompatibleLiveAnalyzerInputConverter:
    LiveAnalyzerInputConverting
{
    private let analyzerFormat: AVAudioFormat

    init(analyzerFormat: AVAudioFormat) {
        self.analyzerFormat = analyzerFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> [AnalyzerInput] {
        guard buffer.format == analyzerFormat else {
            throw LiveInputConversionError.unsupportedFormat
        }
        return [AnalyzerInput(buffer: buffer)]
    }

    func flush() throws -> [AnalyzerInput] {
        []
    }
}

private func makeLiveInputConverter(
    analyzerFormat: AVAudioFormat
) -> any LiveAnalyzerInputConverting {
    if #available(macOS 27.0, *) {
        return NativeLiveAnalyzerInputConverter(
            analyzerFormat: analyzerFormat
        )
    }
    return CompatibleLiveAnalyzerInputConverter(
        analyzerFormat: analyzerFormat
    )
}

private enum LiveInputConversionError: Error {
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
