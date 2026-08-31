import Foundation
import Combine

enum NoteMergeError: LocalizedError {
    case libraryChanged
    case libraryLoading
    case ambiguousSource
    case sourceChanged
    case unfinishedMarkdown
    case draftSaveFailed(String)
    case draftsChanged
    case alreadyRunning
    case alreadyMerged
    case invalidResult
    case saveUncertain

    var errorDescription: String? {
        switch self {
        case .libraryChanged:
            "The notes folder changed while merging. Review the original notes before continuing."
        case .libraryLoading:
            "Wait for the notes folder to finish loading before merging."
        case .ambiguousSource:
            "Review the copies with a shared note ID before merging."
        case .sourceChanged:
            "A selected note changed or is no longer available. Review both notes before merging."
        case .unfinishedMarkdown:
            "Save or discard your Markdown changes before merging notes."
        case .draftSaveFailed(let reason):
            "My notes couldn’t be saved, so the merge did not start. \(reason)"
        case .draftsChanged:
            "You edited one of these notes while the merge was running. Your unfinished words were kept."
        case .alreadyRunning:
            "A merge is already running in this window."
        case .alreadyMerged:
            "These notes were already merged in this window. Review the retained copy instead of merging them again."
        case .invalidResult:
            "The merged result did not belong to the selected notes. The originals were kept."
        case .saveUncertain:
            "Nook may have saved the merged note, but couldn’t verify it. Nook did not remove the other note. Inspect both files before continuing; do not merge these notes again."
        }
    }
}

/// The two-note save boundary outlives a picker and an asynchronous summary.
/// Editor checks happen before snapshots are captured, and again before any
/// save or cleanup can discard an editor's new words.
@MainActor
final class NoteMergeWorkflow: ObservableObject {
    struct Input: Sendable {
        let incoming: MeetingNote
        let target: MeetingNote
        let recordingsDirectory: URL
        let validateAudioCommit: @MainActor @Sendable () throws -> Void
    }

    struct Completion {
        let saved: MeetingNote
        let absorbed: MeetingNote
        let audioOutcome: NoteCombiner.AudioOutcome
        /// Nook did not remove this source. Another filesystem writer can
        /// still have changed or removed it independently.
        let retainedCopy: Bool
        let problem: String?

        var hasPartialSuccess: Bool { retainedCopy || problem != nil }

        var notice: String {
            if retainedCopy {
                let detail = problem.map { " \($0)" } ?? ""
                return "Merged into “\(saved.title)”. Nook did not remove the other Markdown file. Review both notes in the original folder; do not merge these notes again.\(detail)"
            }
            if let problem {
                return "Merged into “\(saved.title)”, but the recordings could not be joined: \(problem)"
            }
            switch audioOutcome {
            case .concatenated:
                return "Merged into “\(saved.title)”. Both recordings were joined into one, and the other note moved to the Trash."
            case .adoptedFromAbsorbed:
                return "Merged into “\(saved.title)”. Its recording was kept, and the other note moved to the Trash."
            case .targetOnly:
                return "Merged into “\(saved.title)”. The existing recording was kept, and the other note moved to the Trash."
            case .none:
                return "Merged into “\(saved.title)”, and the other note moved to the Trash."
            }
        }
    }

    typealias Combine = @Sendable (Input) async throws -> NoteCombiner.Result

    @Published private(set) var isRunning = false
    private let combine: Combine
    /// Suppresses another callback or an immediate remerge after partial
    /// success. This is window-lifetime protection, not a persisted receipt.
    private var completedPairs: Set<Set<LibraryNoteIdentity>> = []

    init(combine: @escaping Combine = { input in
        try await NoteCombiner.merge(
            input.incoming, into: input.target,
            recordingsDirectory: input.recordingsDirectory,
            summarizer: SummaryService(),
            validatingBeforeAudioCommit: input.validateAudioCommit
        )
    }) {
        self.combine = combine
    }

    static func settleDrafts(
        store: MarkdownStore,
        markdown: MarkdownDraftController,
        personal: PersonalNotesDraftController
    ) throws {
        // Raw source has an explicit Save/Discard choice. Never silently
        // choose for it merely because the next operation is destructive.
        guard !markdown.hasChanges else { throw NoteMergeError.unfinishedMarkdown }
        if let reason = personal.saveIfNeeded(store: store) {
            throw NoteMergeError.draftSaveFailed(reason)
        }
    }

    func merge(
        _ incoming: MeetingNote, into target: MeetingNote,
        store: MarkdownStore,
        markdown: MarkdownDraftController,
        personal: PersonalNotesDraftController,
        expectedGeneration: Int? = nil
    ) async throws -> Completion {
        try Task.checkCancellation()
        // The UI schedules this call in a Task. Its captured scope must still
        // be current even if SwiftUI has not delivered onChange cancellation.
        if let expectedGeneration, expectedGeneration != store.storageGeneration {
            throw NoteMergeError.libraryChanged
        }
        guard !isRunning else { throw NoteMergeError.alreadyRunning }
        let pair = Set([incoming.libraryIdentity, target.libraryIdentity])
        guard pair.count == 2, incoming.id != target.id else {
            throw NoteMergeError.invalidResult
        }
        guard !completedPairs.contains(pair) else { throw NoteMergeError.alreadyMerged }
        let directory = store.storageURL.standardizedFileURL
        let generation = store.storageGeneration
        // A stale picker does not authorize even an automatic draft save.
        for note in [incoming, target] {
            try store.validateMergeSource(note, directory: directory, generation: generation)
        }
        try Self.settleDrafts(store: store, markdown: markdown, personal: personal)
        guard let freshIncoming = store.note(matching: incoming.libraryIdentity),
              let freshTarget = store.note(matching: target.libraryIdentity)
        else { throw NoteMergeError.sourceChanged }
        let boundary = Boundary(
            incoming: freshIncoming, target: freshTarget,
            directory: directory, generation: generation,
            store: store, markdown: markdown, personal: personal
        )
        try boundary.validateBeforeSave()
        isRunning = true
        defer { isRunning = false }
        let result = try await combine(Input(
            incoming: freshIncoming, target: freshTarget,
            recordingsDirectory: directory.appendingPathComponent(".recordings", isDirectory: true),
            validateAudioCommit: { try boundary.validateAfterSave() }
        ))
        try boundary.validateBeforeSave()
        let expectedSurvivor = freshIncoming.startedAt < freshTarget.startedAt
            ? freshIncoming : freshTarget
        let expectedAbsorbed = freshIncoming.startedAt < freshTarget.startedAt
            ? freshTarget : freshIncoming
        guard result.merged.libraryIdentity == expectedSurvivor.libraryIdentity,
              result.merged.fileRevision == expectedSurvivor.fileRevision,
              result.absorbed.libraryIdentity == expectedAbsorbed.libraryIdentity,
              result.absorbed.fileRevision == expectedAbsorbed.fileRevision
        else { throw NoteMergeError.invalidResult }
        let saved: MeetingNote
        do {
            saved = try store.save(result.merged) {
                try boundary.validateBeforeSave()
            }
        } catch MarkdownStoreError.saveReadBackFailed {
            // Publication precedes read-back. Treating this as an ordinary
            // retryable failure could append the absorbed words twice.
            completedPairs.insert(pair)
            store.reload()
            throw NoteMergeError.saveUncertain
        }
        boundary.saved = saved
        boundary.absorbed = expectedAbsorbed
        completedPairs.insert(pair)
        // Keeping the earlier note selected does not recreate its detail
        // editor. Advance only its clean source to the confirmed saved bytes
        // so the next ordinary edit does not begin from a stale baseline.
        if markdown.libraryIdentity == saved.libraryIdentity, !markdown.hasChanges {
            markdown.refresh(for: saved, store: store)
        }

        // From here on the text is already merged. A failure is partial
        // success, never a suggestion to append those words a second time.
        do {
            try boundary.validateAfterSave()
            try await result.commitAudio()
            try boundary.validateAfterSave()
        } catch {
            return Completion(
                saved: saved, absorbed: expectedAbsorbed,
                audioOutcome: result.audioOutcome, retainedCopy: true,
                problem: error is CancellationError
                    ? "The merge was stopped before cleanup finished."
                    : error.localizedDescription
            )
        }
        let deleted = store.delete(expectedAbsorbed) {
            try boundary.validateAfterSave()
        }
        return Completion(
            saved: saved, absorbed: expectedAbsorbed,
            audioOutcome: result.audioOutcome, retainedCopy: !deleted,
            problem: deleted ? nil : store.lastError
        )
    }

    @MainActor
    private final class Boundary {
        let incoming: MeetingNote
        let target: MeetingNote
        let directory: URL
        let generation: Int
        let store: MarkdownStore
        let markdown: MarkdownDraftController
        let personal: PersonalNotesDraftController
        var saved: MeetingNote?
        var absorbed: MeetingNote?

        init(
            incoming: MeetingNote, target: MeetingNote, directory: URL,
            generation: Int, store: MarkdownStore,
            markdown: MarkdownDraftController, personal: PersonalNotesDraftController
        ) {
            self.incoming = incoming
            self.target = target
            self.directory = directory
            self.generation = generation
            self.store = store
            self.markdown = markdown
            self.personal = personal
        }

        func validateBeforeSave() throws {
            try validateDrafts()
            for note in [incoming, target] {
                try store.validateMergeSource(note, directory: directory, generation: generation)
            }
        }

        func validateAfterSave() throws {
            try validateDrafts()
            guard let saved, let absorbed else { throw NoteMergeError.invalidResult }
            for note in [saved, absorbed] {
                try store.validateMergeSource(note, directory: directory, generation: generation)
            }
        }

        private func validateDrafts() throws {
            try Task.checkCancellation()
            let ids = Set([incoming.id, target.id])
            let markdownChanged = markdown.hasChanges
                && markdown.noteID.map(ids.contains) == true
            let personalChanged = personal.hasExactChanges
                && personal.noteID.map(ids.contains) == true
            let parked = personal.parkedDrafts.contains {
                $0.owner.matches(incoming) || $0.owner.matches(target)
            }
            guard !markdownChanged, !personalChanged, !parked else {
                throw NoteMergeError.draftsChanged
            }
        }
    }
}
