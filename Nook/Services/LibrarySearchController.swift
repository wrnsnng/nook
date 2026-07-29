import Foundation

@MainActor
final class LibrarySearchController: ObservableObject {
    @Published private(set) var matchingIDs: Set<MeetingNote.ID>?
    @Published private(set) var isSearching = false

    private var searchTask: Task<Void, Never>?

    func update(query: String, notes: [MeetingNote]) {
        searchTask?.cancel()
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedQuery.isEmpty else {
            matchingIDs = nil
            isSearching = false
            return
        }

        matchingIDs = []
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }

            let ids = await Task.detached(priority: .userInitiated) {
                Self.matches(query: trimmedQuery, notes: notes)
            }.value
            guard !Task.isCancelled else { return }
            isSearching = false
            matchingIDs = ids
        }
    }

    nonisolated static func matches(
        query: String,
        notes: [MeetingNote]
    ) -> Set<MeetingNote.ID> {
        let terms = query
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).localizedLowercase }
        return Set(notes.compactMap { note in
            let document = [
                note.title,
                note.summary,
                note.sourceApp,
                note.keyPoints.joined(separator: " "),
                note.decisions.joined(separator: " "),
                note.actionItems.joined(separator: " "),
                note.personalNotes,
                note.transcriptText,
            ].joined(separator: "\n").localizedLowercase
            return terms.allSatisfy(document.contains) ? note.id : nil
        })
    }
}
