import Foundation
@testable import Nook

/// Read-only architecture experiment, compiled into tests only. It deliberately
/// has no conversion from a discovered entry to a partial MeetingNote.
enum LibraryLoadingSpike {
    typealias Entry = LibraryDiscovery.Entry
    typealias Catalog = LibraryDiscovery.Catalog
    typealias Cache = LibraryDiscovery.Cache
    enum Failure: Error { case sourceChanged, incompleteCatalog }

    static func scan(_ directory: URL, cache: inout Cache) throws -> Catalog {
        try LibraryDiscovery.scan(directory, cache: &cache)
    }

    static func load(_ entry: Entry) throws -> MeetingNote {
        try LibraryDiscovery.load(entry)
    }

    private static func read(_ entry: Entry) throws -> Data {
        let bytes = try Data(contentsOf: entry.fileURL)
        guard MeetingNote.contentRevision(bytes) == entry.revision else { throw Failure.sourceChanged }
        return bytes
    }

    struct SearchCache {
        struct Document {
            let revision: Data
            let text: String
        }
        var documents: [LibraryNoteIdentity: Document] = [:]
    }

    static func search(_ query: String, catalog: Catalog) throws -> Set<LibraryNoteIdentity> {
        var cache = SearchCache()
        return try search(query, catalog: catalog, cache: &cache)
    }

    /// Indexes every full document once, retaining searchable text rather than
    /// full models. Even a cache hit rechecks bytes: an old catalog alone cannot
    /// authorize returning a stale hit after an external edit.
    static func search(
        _ query: String, catalog: Catalog, cache: inout SearchCache
    ) throws -> Set<LibraryNoteIdentity> {
        try Task.checkCancellation()
        guard catalog.issues.isEmpty else { throw Failure.incompleteCatalog }
        let terms = query.split(whereSeparator: \.isWhitespace)
            .map { LibrarySearchTerm(String($0).localizedLowercase) }
        let current = Set(catalog.entries.map(\.identity))
        cache.documents = cache.documents.filter { current.contains($0.key) }
        var matches: Set<LibraryNoteIdentity> = []
        for entry in catalog.entries {
            try Task.checkCancellation()
            // Streaming Swift models is not enough: the codec also creates
            // temporary Foundation objects. Drain them before the next file.
            let matched = try autoreleasepool {
                let document: String
                if let cached = cache.documents[entry.identity], cached.revision == entry.revision {
                    _ = try read(entry)
                    document = cached.text
                } else {
                    let note = try load(entry)
                    document = LibrarySearchController.document(for: note)
                    cache.documents[entry.identity] = .init(revision: entry.revision, text: document)
                }
                return terms.allSatisfy { $0.matches(in: document) }
            }
            if matched { matches.insert(entry.identity) }
        }
        try Task.checkCancellation()
        return matches
    }
}
