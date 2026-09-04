import Foundation

/// One background write-up per physical note, shared with the detail editor.
/// No separate persistence lives here; Markdown remains the durable state.
@MainActor
final class NoteSummarySessions {
    private var sessions: [LibraryNoteIdentity: SummaryRegenerationSession] = [:]
    private let makeSession: @MainActor () -> SummaryRegenerationSession

    init(makeSession: @escaping @MainActor () -> SummaryRegenerationSession = {
        SummaryRegenerationSession()
    }) {
        self.makeSession = makeSession
    }

    func session(for note: MeetingNote) -> SummaryRegenerationSession {
        if let existing = sessions[note.libraryIdentity] { return existing }
        let session = makeSession()
        sessions[note.libraryIdentity] = session
        return session
    }

    @discardableResult
    func enrich(
        _ note: MeetingNote, purpose: SummaryRegenerationSession.Purpose,
        store: MarkdownStore, runner: SummaryRegenerationSession.Runner? = nil
    ) -> Task<Void, Never>? {
        guard SummaryRegenerator.isAvailable(for: note) else { return nil }
        if let runner {
            sessions.removeValue(forKey: note.libraryIdentity)?.cancel()
            sessions[note.libraryIdentity] = SummaryRegenerationSession(runner: runner)
        }
        let session = session(for: note)
        // A second sitting supersedes the older input. Invalidate first so
        // even an uncooperative older model cannot commit after this start.
        session.cancel()
        return session.start(note: note, purpose: purpose, library: { [weak store] in
            guard let store else {
                return .init(directoryURL: URL(fileURLWithPath: "/"), generation: -1, notes: [])
            }
            return .init(directoryURL: store.storageURL, generation: store.storageGeneration, notes: store.notes)
        }, commit: { [weak store] updated in
            guard let store else { throw CancellationError() }
            return try store.save(updated)
        })
    }

    func reconcile(notes: [MeetingNote], duplicateIDs: Set<UUID>) {
        let owned = Set(notes.filter { !duplicateIDs.contains($0.id) }.map(\.libraryIdentity))
        for identity in Array(sessions.keys) where !owned.contains(identity) {
            sessions.removeValue(forKey: identity)?.cancel()
        }
    }

    func removeAll() {
        for session in sessions.values { session.cancel() }
        sessions.removeAll()
    }
}
