import Foundation

/// Reuses a saved note's searchable document only for the same file and exact
/// content revision. Timestamps can survive an external edit, and a copied
/// library carries its note UUIDs with it. Neither can authorize a cache hit.
/// Revisionless or unsaved models are rebuilt because they have no immutable
/// file snapshot whose identity can prove their content is unchanged.
actor SearchDocumentCache {
    private var entries: [LibraryNoteIdentity: (revision: Data, document: String)] = [:]

    func documents(for notes: [MeetingNote]) -> [LibraryNoteIdentity: String] {
        var result: [LibraryNoteIdentity: String] = [:]
        result.reserveCapacity(notes.count)
        for note in notes {
            guard !Task.isCancelled else { return [:] }
            let identity = note.libraryIdentity
            guard note.fileURL != nil, let revision = note.fileRevision else {
                entries.removeValue(forKey: identity)
                result[identity] = LibrarySearchController.document(for: note)
                continue
            }
            if let cached = entries[identity], cached.revision == revision {
                result[identity] = cached.document
            } else {
                let document = LibrarySearchController.document(for: note)
                entries[identity] = (revision, document)
                result[identity] = document
            }
        }
        // Changing folders and deleting notes must release documents from the
        // previous library, including a different file sharing the same UUID.
        let currentIDs = Set(notes.map(\.libraryIdentity))
        entries = entries.filter { currentIDs.contains($0.key) }
        return result
    }
}

@MainActor
final class LibrarySearchController: ObservableObject {
    @Published private(set) var matchingIDs: Set<LibraryNoteIdentity>?
    @Published private(set) var isSearching = false

    private var searchTask: Task<Void, Never>?
    private let documentCache = SearchDocumentCache()
    private let matcher: @Sendable (String, [MeetingNote], [LibraryNoteIdentity: String]) async -> Set<LibraryNoteIdentity>

    init(
        matcher: @escaping @Sendable (String, [MeetingNote], [LibraryNoteIdentity: String]) async -> Set<LibraryNoteIdentity> = { query, notes, documents in
            LibrarySearchController.matches(query: query, notes: notes, documents: documents)
        }
    ) {
        self.matcher = matcher
    }

    deinit {
        searchTask?.cancel()
    }

    func update(query: String, notes: [MeetingNote]) {
        searchTask?.cancel()
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedQuery.isEmpty else {
            // Cancel first even when this is already the unfiltered state.
            // An unchanged empty query must not rebuild the Library on save.
            if matchingIDs != nil { matchingIDs = nil }
            if isSearching { isSearching = false }
            return
        }

        matchingIDs = []
        isSearching = true
        searchTask = Task { [weak self, documentCache, matcher] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }

            let documents = await documentCache.documents(for: notes)
            guard !Task.isCancelled else { return }

            let worker = Task.detached(priority: .userInitiated) {
                await matcher(trimmedQuery, notes, documents)
            }
            // Detached work does not inherit later cancellation. Without this
            // link, each superseded query can finish a full library scan even
            // though its result will never be displayed.
            let ids = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            self?.isSearching = false
            self?.matchingIDs = ids
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
        documents: [LibraryNoteIdentity: String]? = nil
    ) -> Set<LibraryNoteIdentity> {
        let terms = query
            .split(whereSeparator: \.isWhitespace)
            .map { LibrarySearchTerm(String($0).localizedLowercase) }
        var result: Set<LibraryNoteIdentity> = []
        for note in notes {
            guard !Task.isCancelled else { return [] }
            let identity = note.libraryIdentity
            let document = documents?[identity] ?? Self.document(for: note)
            if terms.allSatisfy({ $0.matches(in: document) }) {
                result.insert(identity)
            }
        }
        return result
    }
}

/// Swift's Character search preserves canonical equivalence and grapheme
/// boundaries, but scanning a long transcript for a missing word is costly.
/// Lowercase ASCII letters and digits have no alternate canonical spellings,
/// so literal lookup can find their candidates without normalizing documents.
/// Do not broaden this alphabet to uppercase or punctuation: the Kelvin sign
/// and Greek question mark are canonical aliases for "K" and ";" respectively.
struct LibrarySearchTerm: Sendable {
    let text: String
    private let usesLiteralSearch: Bool

    init(_ text: String) {
        self.text = text
        usesLiteralSearch = !text.isEmpty && text.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0)
        }
    }

    func matches(in document: String) -> Bool {
        guard usesLiteralSearch else { return document.contains(text) }
        let range = (document as NSString).range(of: text, options: .literal)
        guard range.location != NSNotFound else { return false }

        let lower = String.Index(utf16Offset: range.location, in: document)
        let upper = String.Index(utf16Offset: NSMaxRange(range), in: document)
        if let start = String.Index(lower, within: document),
           let end = String.Index(upper, within: document),
           document[start..<end] == text {
            return true
        }
        // Literal search may stop inside an accented letter or emoji. Keep
        // Swift's existing answer, including a valid match later in the text;
        // repeatedly searching partial candidates could turn into quadratic
        // work when converting their UTF-16 offsets in a large document.
        return document.contains(text)
    }
}
