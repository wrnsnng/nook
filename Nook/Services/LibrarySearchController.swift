import Foundation

/// Caches each note's lowercased searchable document, keyed by note id and
/// `fileModified`, so a query does not rejoin and lowercase every note's
/// full transcript on every keystroke. An actor because it is populated
/// from the search controller's detached task, off the main actor.
actor SearchDocumentCache {
    private var entries: [MeetingNote.ID: (fileModified: Date?, document: String)] = [:]

    func documents(for notes: [MeetingNote]) -> [MeetingNote.ID: String] {
        var result: [MeetingNote.ID: String] = [:]
        result.reserveCapacity(notes.count)
        for note in notes {
            if let cached = entries[note.id],
               cached.fileModified == note.fileModified {
                result[note.id] = cached.document
            } else {
                let document = LibrarySearchController.document(for: note)
                entries[note.id] = (note.fileModified, document)
                result[note.id] = document
            }
        }
        // Notes no longer in the library have nothing left to reuse their
        // entry, so drop it rather than growing this forever.
        let currentIDs = Set(notes.map(\.id))
        entries = entries.filter { currentIDs.contains($0.key) }
        return result
    }
}

@MainActor
final class LibrarySearchController: ObservableObject {
    @Published private(set) var matchingIDs: Set<MeetingNote.ID>?
    @Published private(set) var isSearching = false

    private var searchTask: Task<Void, Never>?
    private let documentCache = SearchDocumentCache()

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
        searchTask = Task { [documentCache] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }

            let documents = await documentCache.documents(for: notes)
            guard !Task.isCancelled else { return }

            let ids = await Task.detached(priority: .userInitiated) {
                Self.matches(
                    query: trimmedQuery,
                    notes: notes,
                    documents: documents
                )
            }.value
            guard !Task.isCancelled else { return }
            isSearching = false
            matchingIDs = ids
        }
    }

    /// The document `matches` searches for one note: every field a query can
    /// match, joined and lowercased once.
    nonisolated static func document(for note: MeetingNote) -> String {
        [
            note.title,
            note.summary,
            note.sourceApp,
            note.keyPoints.joined(separator: " "),
            note.decisions.joined(separator: " "),
            note.actionItems.joined(separator: " "),
            note.personalNotes,
            note.transcriptText,
        ].joined(separator: "\n").localizedLowercase
    }

    /// `documents` lets a caller that already has each note's searchable
    /// document (see `SearchDocumentCache`) skip rebuilding it here; without
    /// one, every note's document is built fresh, exactly as before.
    nonisolated static func matches(
        query: String,
        notes: [MeetingNote],
        documents: [MeetingNote.ID: String]? = nil
    ) -> Set<MeetingNote.ID> {
        let terms = query
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).localizedLowercase }
        return Set(notes.compactMap { note in
            let document = documents?[note.id] ?? Self.document(for: note)
            return terms.allSatisfy(document.contains) ? note.id : nil
        })
    }
}
