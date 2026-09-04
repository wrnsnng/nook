import Foundation
import Combine

/// Owns a single regeneration request independently of SwiftUI's render and
/// navigation timing. Cancellation is an immediate invalidation, even if a
/// summarizer ignores it and later reports progress or a result.
@MainActor
final class SummaryRegenerationSession: ObservableObject {
    enum Purpose {
        case regeneration
        case initial
        case appended

        static func forRetry(of note: MeetingNote) -> Self {
            switch note.summaryPending {
            case .initial: .initial
            case .appended: .appended
            case nil: .regeneration
            }
        }
    }
    struct LibrarySnapshot {
        let directoryURL: URL
        let generation: Int
        let notes: [MeetingNote]

        func note(matching identity: LibraryNoteIdentity) -> MeetingNote? {
            guard let file = identity.fileURL,
                  file.deletingLastPathComponent().standardizedFileURL == directoryURL.standardizedFileURL else {
                return nil
            }
            let matches = notes.filter { $0.id == identity.noteID }
            guard matches.count == 1, matches[0].libraryIdentity == identity else { return nil }
            return matches[0]
        }
    }

    enum Result {
        case saved(MeetingNote)
        case retained(SummaryService.FailureReason?)
        case failed(String)
    }

    struct Completion: Identifiable {
        let id = UUID()
        let result: Result
    }

    typealias Runner = @Sendable (MeetingNote, SummaryStageHandler?) async -> SummaryRegenerator.Outcome
    typealias LibraryReader = @MainActor () -> LibrarySnapshot
    typealias Commit = @MainActor (MeetingNote) throws -> MeetingNote

    @Published private(set) var stage: SummaryStage?
    @Published private(set) var completion: Completion?
    @Published private(set) var wasCancelled = false
    private let runner: Runner
    private let timeout: TimeInterval?
    private var purpose: Purpose = .regeneration
    private var requestID: UUID?
    private var task: Task<Void, Never>?

    init(runner: Runner? = nil, timeout: TimeInterval? = nil) {
        self.timeout = timeout
        self.runner = runner ?? { note, onStage in
            await SummaryRegenerator.regenerate(note, using: SummaryService(), onStage: onStage)
        }
    }

    deinit { task?.cancel() }

    var isRunning: Bool { requestID != nil }

    func waitForCompletion() async { await task?.value }

    func statusMessage(summaryPending: Bool) -> String? {
        if wasCancelled {
            return "Summary cancelled. Your saved transcript and notes are unchanged."
        }
        if let completion {
            switch completion.result {
            case .failed(let message): return message
            case .retained(let reason):
                if let reason { return RegenerationCopy.retainedMessage(for: reason) }
            case .saved: break
            }
        }
        return summaryPending
            ? "Summary not finished. Your transcript is saved. Open Transcript to read it, or Retry when you’re ready."
            : nil
    }

    @discardableResult
    func start(
        note: MeetingNote, purpose: Purpose = .regeneration,
        library: @escaping LibraryReader, commit: @escaping Commit
    ) -> Task<Void, Never>? {
        guard !isRunning else { return nil }
        let snapshot = library()
        guard let starting = snapshot.note(matching: note.libraryIdentity),
              starting.fileRevision != nil,
              SummaryRegenerator.isAvailable(for: starting) else {
            completion = Completion(result: .failed("This note is no longer available for regeneration in this library."))
            return nil
        }
        let folder = snapshot.directoryURL.standardizedFileURL
        let generation = snapshot.generation
        let id = UUID()
        requestID = id
        self.purpose = purpose
        completion = nil
        wasCancelled = false
        stage = .condensing(pass: 1, part: 0, total: 0)
        let runner = runner
        let seconds = timeout ?? MeetingCoordinator.summaryDeadline(
            forTranscriptCharacters: starting.transcript.reduce(0) { $0 + $1.text.count },
            isTerminating: false
        )
        let work = Task { [weak self] in
            // Callers may cancel the returned task rather than the session.
            // Retire that request too, but never clear a newer retry's state.
            defer {
                if Task.isCancelled, self?.requestID == id { self?.cancel() }
            }
            guard !Task.isCancelled, self?.requestID == id else { return }
            let onStage: SummaryStageHandler = { [weak self] stage in
                await self?.receive(
                    stage, id: id, starting: starting, folder: folder,
                    generation: generation, library: library
                )
            }
            let outcome = await withDeadline(seconds: seconds) {
                await runner(starting, onStage)
            } ?? .retained(reason: .timedOut)
            guard !Task.isCancelled else { return }
            self?.finish(
                outcome, id: id, starting: starting, folder: folder,
                generation: generation, library: library, commit: commit
            )
        }
        task = work
        return work
    }

    func cancel() {
        if isRunning { wasCancelled = true }
        requestID = nil
        task?.cancel()
        task = nil
        stage = nil
        completion = nil
    }

    private func receive(
        _ stage: SummaryStage, id: UUID, starting: MeetingNote,
        folder: URL, generation: Int, library: LibraryReader
    ) {
        guard requestID == id else { return }
        guard currentNote(starting: starting, folder: folder, generation: generation, library: library) != nil else {
            cancel()
            return
        }
        self.stage = stage
    }

    private func currentNote(
        starting: MeetingNote, folder: URL, generation: Int, library: LibraryReader
    ) -> MeetingNote? {
        let current = library()
        // A → B → A is still a scope change. Checking the URL alone would
        // revive an old request after the user had left its library.
        guard current.directoryURL.standardizedFileURL == folder,
              current.generation == generation else { return nil }
        guard let latest = current.note(matching: starting.libraryIdentity),
              latest.kind == starting.kind, latest.fileRevision != nil else {
            return nil
        }
        return latest
    }

    private func finish(
        _ outcome: SummaryRegenerator.Outcome, id: UUID, starting: MeetingNote,
        folder: URL, generation: Int, library: LibraryReader, commit: Commit
    ) {
        guard requestID == id else { return }
        guard let latest = currentNote(
            starting: starting, folder: folder, generation: generation, library: library
        ) else {
            cancel()
            return
        }
        let result: Result
        switch outcome {
        case .regenerated(let generated):
            guard SummaryRegenerator.hasSameGenerationInput(starting, latest) else {
                complete(.failed("The transcript or summary guidance changed while regeneration ran. Your note was kept. Try again to use the current content."))
                return
            }
            guard generated.libraryIdentity == starting.libraryIdentity else {
                complete(.failed("The generated result did not belong to this note. Your note was kept."))
                return
            }
            var merged: MeetingNote
            switch purpose {
            case .regeneration:
                merged = SummaryRegenerator.mergingGeneratedFields(
                    from: generated, startingFrom: starting, into: latest
                )
            case .initial, .appended:
                let result = SummaryResult(insights: MeetingInsights(
                    title: generated.title, summary: generated.summary,
                    keyPoints: generated.keyPoints, decisions: generated.decisions,
                    actionItems: generated.actionItems, openQuestions: generated.openQuestions
                ), failure: nil)
                merged = purpose == .initial
                    ? MeetingCoordinator.mergingTranscriptFirstSummary(result, scaffold: starting, current: latest) ?? latest
                    : MeetingCoordinator.mergingAppendedSessionSummary(result, scaffold: starting, current: latest) ?? latest
            }
            merged.summaryPending = nil
            do {
                // Preserve the latest revision for the store's final on-disk
                // conflict check. Newer user fields are not a stale-write grant.
                result = .saved(try commit(merged))
            } catch {
                result = .failed(error.localizedDescription)
            }
        case .retained(let reason):
            result = .retained(reason)
        }
        guard requestID == id else { return }
        complete(result)
    }

    private func complete(_ result: Result) {
        requestID = nil
        task = nil
        stage = nil
        completion = Completion(result: result)
    }
}
