import AVFoundation
import CoreMedia
import Foundation
import os
import Speech

struct LiveTranscriptState: Equatable, Sendable {
    var segments: [TranscriptSegment] = []
    var meetingPartial = ""
    var microphonePartial = ""
    var latestSource: TranscriptSegment.Source = .system
    var revision = 0
    /// Maintained by `LiveSegmentMerger` as lines are folded in. Recounting
    /// it per interface update split every word of every segment of the whole
    /// meeting so far, at whatever rate the surface repainted.
    var wordCount = 0

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
    /// How many finalized results of each track have been folded into the
    /// published transcript. A snapshot whose count has not moved carries only
    /// partial revisions, which never change finalized text.
    private var consumedFinalCounts: [TranscriptSegment.Source: Int] = [:]
    private var merger = LiveSegmentMerger()
    /// Partial revisions arrive many times per second while anyone speaks.
    /// Republishing each one invalidated every observer of the coordinator far
    /// faster than captions can be read, and starved the one-second elapsed
    /// clock badly enough that it visibly jumped ahead. Partials are
    /// throttled; anything with newly finalized speech goes out immediately.
    private static let minimumPartialInterval: TimeInterval = 0.1
    private var lastPublishAt: Date?
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
        consumedFinalCounts = [:]
        merger.reset()
        isRunning = true
        meetingTrack.start()
        microphoneTrack.start()
        publish(force: true)
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
            LiveSegmentMerger.deduplicated(mergedSegments())
        )
        tracks.removeAll()
        consumedFinalCounts = [:]
        merger.reset()
        publish(force: true)
        return result
    }

    func cancel() async {
        isRunning = false
        for track in tracks.values {
            await track.cancel()
        }
        tracks.removeAll()
        trackStates.removeAll()
        consumedFinalCounts = [:]
        merger.reset()
        publish(force: true)
    }

    private func receive(_ snapshot: TrackSnapshot) {
        let consumed = consumedFinalCounts[snapshot.source] ?? 0
        trackStates[snapshot.source] = snapshot
        guard consumed < snapshot.segments.count else {
            // A partial revision. Finalized text is unchanged, so the cached
            // transcript is republished as-is instead of being recomputed.
            publish(force: false)
            return
        }
        consumedFinalCounts[snapshot.source] = snapshot.segments.count
        merger.consume(snapshot.segments[consumed...])
        publish(force: true)
    }

    private func publish(force: Bool) {
        let now = Date()
        if !force,
           let last = lastPublishAt,
           now.timeIntervalSince(last) < Self.minimumPartialInterval {
            return
        }
        lastPublishAt = now

        let meeting = trackStates[.system] ?? TrackSnapshot(source: .system)
        let microphone = trackStates[.microphone] ?? TrackSnapshot(source: .microphone)
        let newest = [meeting, microphone].max { lhs, rhs in
            lhs.lastChangedAt < rhs.lastChangedAt
        }

        var state = LiveTranscriptState(
            segments: merger.coalesced,
            meetingPartial: meeting.partial,
            microphonePartial: microphone.partial,
            latestSource: newest?.source ?? .system,
            revision: meeting.revision + microphone.revision,
            wordCount: merger.totalWords
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
            .sorted { LiveSegmentMerger.ordersBefore($0, $1) }
    }


}

struct TrackSnapshot: Sendable {
    let source: TranscriptSegment.Source
    private(set) var segments: [TranscriptSegment] = []
    private var finalizedRanges: Set<CMTimeRange> = []
    var partial = ""
    var revision = 0
    var lastChangedAt = Date.distantPast

    init(source: TranscriptSegment.Source) { self.source = source }

    mutating func appendFinalized(_ text: String, range: CMTimeRange) {
        // A final may be emitted twice for one span. Text is not its identity:
        // repeating "No" later means both occurrences belong in the note.
        if range.isValid, !range.isIndefinite,
           !finalizedRanges.insert(range).inserted { return }
        segments.append(TranscriptSegment(
            startTime: max(0, range.start.seconds),
            duration: max(0, range.duration.seconds),
            text: text,
            source: source
        ))
    }
}

/// Maintains the published live transcript incrementally.
///
/// Every partial revision used to rebuild the entire transcript: merge-sort
/// every segment, rescan duplicates across the whole history, regex-clean all
/// of it again. Partials arrive continuously during speech, so the cost grew
/// with meeting length exactly while captions needed to stay cheap. Finals
/// are folded in as they arrive instead; a partial-only update republishes
/// cached segments untouched.
///
/// The fold mirrors one step of `TranscriptAssembler.coalesce`, so appending
/// at the end is exact. Anything that lands elsewhere (a late out-of-order
/// final, or a system-audio duplicate replacing a microphone line) reports it,
/// and the caller falls back to one full rebuild using the same coalesce pass
/// `stop()` uses. What reaches the saved note is therefore always computed by
/// the authoritative pipeline; this type only shapes what captions show live.
struct LiveSegmentMerger {
    /// All finalized segments so far, time-sorted and duplicate-free.
    private(set) var interleaved: [TranscriptSegment] = []
    /// The coalesced form of `interleaved` that caption surfaces render.
    private(set) var coalesced: [TranscriptSegment] = []
    /// Running total over `coalesced`. Recomputing it per interface update is
    /// what made long meetings progressively slower to repaint.
    private(set) var totalWords = 0
    /// A system span can explain one microphone echo, not several genuine
    /// repetitions whose measured ranges happen to overlap it.
    private var pairedSystemSegments: Set<TranscriptSegment.ID> = []

    /// Duplicates land within seconds of their twin, so scanning back past
    /// this window cannot miss one.
    private static let duplicateWindow: TimeInterval = 4

    static func words(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    static func sourceRank(_ source: TranscriptSegment.Source) -> Int {
        switch source {
        case .microphone: 0
        case .mixed: 1
        case .system: 2
        }
    }

    static func ordersBefore(
        _ lhs: TranscriptSegment,
        _ rhs: TranscriptSegment
    ) -> Bool {
        if lhs.startTime != rhs.startTime {
            return lhs.startTime < rhs.startTime
        }
        return sourceRank(lhs.source) < sourceRank(rhs.source)
    }

    private static func isCrossSourceEcho(
        _ lhs: TranscriptSegment,
        _ rhs: TranscriptSegment
    ) -> Bool {
        guard (lhs.source == .microphone && rhs.source == .system)
            || (lhs.source == .system && rhs.source == .microphone),
            abs(lhs.startTime - rhs.startTime) < duplicateWindow,
            lhs.duration > 0, rhs.duration > 0 else { return false }
        let overlap = min(lhs.startTime + lhs.duration, rhs.startTime + rhs.duration)
            - max(lhs.startTime, rhs.startTime)
        guard overlap >= max(lhs.duration, rhs.duration) * 0.5 else { return false }
        // Shared vocabulary erased negation and amounts. Keep every word and
        // punctuation mark; normalize only case and whitespace. An uncertain
        // echo costs a duplicate rather than losing somebody's speech.
        let left = lhs.text.lowercased().split(whereSeparator: \.isWhitespace)
        let right = rhs.text.lowercased().split(whereSeparator: \.isWhitespace)
        // Short agreements can be spoken on both sides simultaneously.
        return left.count >= 3 && left == right
    }

    /// The input is time-sorted. Use the same conservative echo rule for the
    /// saved note as for live captions, scanning only the nearby time window.
    static func deduplicated(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        var pairedSystemSegments: Set<TranscriptSegment.ID> = []
        for segment in segments {
            var mergedWithDuplicate = false
            var index = result.count - 1
            while index >= 0,
                  abs(result[index].startTime - segment.startTime) < duplicateWindow {
                let systemID = segment.source == .system ? segment.id : result[index].id
                if !pairedSystemSegments.contains(systemID),
                   isCrossSourceEcho(result[index], segment) {
                    pairedSystemSegments.insert(systemID)
                    if segment.source == .system {
                        result.remove(at: index)
                        result.insert(segment, at: insertionIndex(for: segment, in: result))
                    }
                    mergedWithDuplicate = true
                    break
                }
                index -= 1
            }
            if !mergedWithDuplicate { result.append(segment) }
        }
        return result
    }

    mutating func reset() {
        interleaved = []
        coalesced = []
        totalWords = 0
        pairedSystemSegments = []
    }

    /// Folds freshly finalized segments in, returning whether any of them
    /// landed somewhere other than the end of the stream.
    @discardableResult
    mutating func consume(_ fresh: ArraySlice<TranscriptSegment>) -> Bool {
        var needsFullRebuild = false
        for segment in fresh {
            if foldIn(segment) {
                needsFullRebuild = true
            }
        }
        if needsFullRebuild {
            // Out-of-order arrivals are rare. One full pass through the same
            // coalesce `stop()` uses costs far less than keeping an
            // insertion-capable fold correct for a case that mostly never
            // happens.
            coalesced = TranscriptAssembler.coalesce(interleaved)
            totalWords = coalesced.reduce(0) { $0 + Self.words(in: $1.text) }
        }
        return needsFullRebuild
    }

    private mutating func foldIn(_ segment: TranscriptSegment) -> Bool {
        // The same sentence recognised on both tracks within seconds. System
        // audio wins, matching the full-pass dedupe preference.
        var index = interleaved.count - 1
        while index >= 0,
              interleaved[index].startTime >= segment.startTime - Self.duplicateWindow {
            let existing = interleaved[index]
            let systemID = segment.source == .system ? segment.id : existing.id
            if !pairedSystemSegments.contains(systemID),
               Self.isCrossSourceEcho(existing, segment) {
                pairedSystemSegments.insert(systemID)
                guard existing.source == .microphone, segment.source == .system else {
                    return false
                }
                totalWords += Self.words(in: segment.text) - Self.words(in: existing.text)
                interleaved.remove(at: index)
                interleaved.insert(
                    segment,
                    at: Self.insertionIndex(for: segment, in: interleaved)
                )
                return true
            }
            index -= 1
        }

        let insertion = Self.insertionIndex(for: segment, in: interleaved)
        interleaved.insert(segment, at: insertion)

        guard insertion == interleaved.count - 1 else {
            return true
        }

        // Appending at the end extends the running fold exactly as a full
        // coalesce would.
        let candidate = segment.normalized
        if let last = coalesced.last,
           let joined = Self.merged(last, next: candidate) {
            totalWords += Self.words(in: joined.text) - Self.words(in: last.text)
            coalesced[coalesced.count - 1] = joined
        } else {
            totalWords += Self.words(in: candidate.text)
            coalesced.append(candidate)
        }
        return false
    }

    private static func insertionIndex(
        for segment: TranscriptSegment,
        in sorted: [TranscriptSegment]
    ) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if ordersBefore(sorted[middle], segment) {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    /// One step of the coalesce fold: whether `next` joins `current`, and the
    /// joined result when it does.
    static func merged(
        _ current: TranscriptSegment,
        next: TranscriptSegment
    ) -> TranscriptSegment? {
        let currentEnd = current.startTime + current.duration
        let gap = max(0, next.startTime - currentEnd)
        let currentWords = current.text.split(whereSeparator: \.isWhitespace).count
        let nextWords = next.text.split(whereSeparator: \.isWhitespace).count
        let hasNaturalEnding = current.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .last
            .map { ".!?".contains($0) }
            ?? false
        let shouldMerge = current.source == next.source
            && gap <= TranscriptAssembler.maximumMergeGap
            && currentWords + nextWords <= TranscriptAssembler.maximumMergeWords
            && (!hasNaturalEnding || currentWords < 5)

        guard shouldMerge else { return nil }

        let nextEnd = next.startTime + next.duration
        let joinedText = [current.text, next.text]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return TranscriptSegment(
            id: current.id,
            startTime: current.startTime,
            duration: max(current.duration, nextEnd - current.startTime),
            text: joinedText,
            source: current.source
        )
    }
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
    /// Set once `finish()` begins draining results. A results sequence that
    /// ends without this flag means the recognizer died mid-meeting rather
    /// than completing, which must be reported instead of trusted as final.
    private var isFinishing = false

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
                // A sequence that ends cleanly while the session is live is a
                // recognizer that stopped without an error: no throw, no
                // callback, and captions that quietly stop growing. Reporting
                // it here clears the completeness flag so the meeting falls
                // back to saved-audio refinement instead of saving the
                // truncation as the finished transcript.
                guard let self, !self.isFinishing, !Task.isCancelled else {
                    return
                }
                self.onError?(
                    "Live \(self.source.label.lowercased()) captions stopped unexpectedly. "
                        + "Nook will refine this transcript from the saved audio."
                )
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
        isFinishing = true
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

        let finished: Void? = await withDeadline(
            seconds: Self.finalizationTimeout
        ) { [weak self] () -> Void in
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

        guard finished == nil else { return }
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

        if result.isFinal {
            snapshot.appendFinalized(text, range: result.range)
            snapshot.partial = ""
        } else {
            snapshot.partial = text
        }
        snapshot.revision += 1
        snapshot.lastChangedAt = Date()
        onUpdate?(snapshot)
    }
}

/// Runs `operation` with a deadline, returning its value or `nil` on timeout.
///
/// A task group is deliberately not used: it awaits every child before
/// returning, so a stalled operation would still block the caller — which is
/// exactly the failure this guards against. The losing task is abandoned.
@MainActor
func withDeadline<Value: Sendable>(
    seconds: Double,
    operation: @escaping @MainActor () async -> Value
) async -> Value? {
    let signal = DeadlineSignal<Value>()
    let work = Task { @MainActor in
        let value = await operation()
        signal.signal(value)
    }
    let timer = Task { @MainActor in
        try? await Task.sleep(for: .seconds(seconds))
        guard !Task.isCancelled else { return }
        signal.signal(nil)
    }

    let result = await signal.wait()
    timer.cancel()
    if result == nil {
        work.cancel()
    }
    return result
}

/// A one-shot main-actor signal that tolerates being resolved before or after
/// the waiter arrives. `nil` means the deadline won.
@MainActor
final class DeadlineSignal<Value: Sendable> {
    private var continuation: CheckedContinuation<Value?, Never>?
    private var hasResolved = false
    private var resolvedValue: Value?

    func wait() async -> Value? {
        if hasResolved { return resolvedValue }
        if Task.isCancelled {
            signal(nil)
            return nil
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Cancellation can win immediately before this continuation
                // is installed. `signal` records that resolution, so the
                // waiter resumes here instead of sleeping until the original
                // 90-to-900-second deadline.
                if hasResolved {
                    continuation.resume(returning: resolvedValue)
                } else {
                    self.continuation = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.signal(nil)
            }
        }
    }

    func signal(_ value: Value?) {
        guard !hasResolved else { return }
        hasResolved = true
        resolvedValue = value
        continuation?.resume(returning: value)
        continuation = nil
    }
}

protocol LiveAnalyzerInputConverting: AnyObject {
    func convert(_ buffer: AVAudioPCMBuffer) throws -> [AnalyzerInput]
    func flush() throws -> [AnalyzerInput]
}

/// Hands one buffer to the converter even if its input callback is queried
/// more than once or from concurrent queues. The caller must leave the samples
/// unchanged until the synchronous conversion returns, as AVAudioConverter
/// requires. The lock guards ownership of the pending reference, not sample
/// mutation, and taking it removes the reference before releasing the lock.
final class AnalyzerInputBufferProvider: Sendable {
    private let pending: OSAllocatedUnfairLock<AVAudioPCMBuffer?>

    init(buffer: AVAudioPCMBuffer?) {
        // AVAudioPCMBuffer is not Sendable. This synchronous borrowing API
        // cannot transfer its caller's buffer into a Mutex with `sending`.
        // The unchecked state initializer keeps that borrow under a lock
        // without a blanket Sendable conformance or copying every audio frame.
        pending = OSAllocatedUnfairLock(uncheckedState: buffer)
    }

    func takeBuffer() -> AVAudioPCMBuffer? {
        pending.withLockUnchecked { buffer in
            let result = buffer
            buffer = nil
            return result
        }
    }
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
            input: buffer,
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
            input: nil,
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

    /// Pulls one output buffer out of `converter`. The source buffer is supplied
    /// once, after which `whenStarved` reports why no more is coming.
    ///
    /// Live conversion must starve with `.noDataNow`: `.endOfStream` moves the
    /// converter into a terminal state and every later buffer in the meeting
    /// would silently yield nothing. Only `flush()` ends the stream.
    private func drain(
        converter: AVAudioConverter,
        capacity: AVAudioFrameCount,
        input: AVAudioPCMBuffer?,
        whenStarved: AVAudioConverterInputStatus
    ) throws -> AVAudioPCMBuffer? {
        guard let output = AVAudioPCMBuffer(
            pcmFormat: analyzerFormat,
            frameCapacity: capacity
        ) else {
            throw LiveInputConversionError.unsupportedFormat
        }

        let provider = AnalyzerInputBufferProvider(buffer: input)
        let inputBlock: AVAudioConverterInputBlock = { _, inputStatus in
            guard let buffer = provider.takeBuffer() else {
                inputStatus.pointee = whenStarved
                return nil
            }
            inputStatus.pointee = .haveData
            return buffer
        }
        var conversionError: NSError?
        let status = converter.convert(
            to: output,
            error: &conversionError,
            withInputFrom: inputBlock
        )

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
