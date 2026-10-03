import Foundation
@testable import Nook

/// Read-only architecture experiment, compiled into tests only. It deliberately
/// has no conversion from a discovered entry to a partial MeetingNote.
enum LibraryLoadingSpike {
    struct Entry: Sendable {
        let metadata: MarkdownCodec.Metadata
        let identity: LibraryNoteIdentity
        let revision: Data
        let fileURL: URL
        let modified: Date?
    }

    struct Catalog: Sendable {
        let entries: [Entry]
        let issues: [MarkdownLoadIssue]
    }

    enum Failure: Error { case invalidDocument, sourceChanged, incompleteCatalog }

    /// Caller-owned, disposable cache. A scan still reads and hashes every
    /// file, and prunes removed paths. Neither mtime nor length proves freshness.
    struct Cache {
        var entries: [URL: Entry] = [:]
    }

    static func scan(_ directory: URL, cache: inout Cache) throws -> Catalog {
        func files(_ folder: URL) throws -> [URL] {
            try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension.lowercased() == "md" }
        }
        var urls = try files(directory)
        var issues: [MarkdownLoadIssue] = []
        for folder in try LibraryFolders.folderURLs(in: directory) {
            do { urls += try files(folder) }
            catch { issues.append(.init(fileURL: folder, message: error.localizedDescription)) }
        }
        var entries: [Entry] = []
        var retained: [URL: Entry] = [:]
        for url in urls {
            try Task.checkCancellation()
            do {
                let bytes = try Data(contentsOf: url)
                let revision = MeetingNote.contentRevision(bytes)
                let key = url.standardizedFileURL
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let metadata: MarkdownCodec.Metadata
                if let cached = cache.entries[key], cached.revision == revision {
                    metadata = cached.metadata
                } else {
                    guard let text = String(data: bytes, encoding: .utf8),
                          let decoded = MarkdownCodec.decodeMetadata(text) else { throw Failure.invalidDocument }
                    metadata = decoded
                }
                let entry = Entry(metadata: metadata,
                                  identity: LibraryNoteIdentity(noteID: metadata.id, fileURL: url),
                                  revision: revision, fileURL: url, modified: modified)
                entries.append(entry)
                retained[key] = entry
            } catch {
                issues.append(.init(fileURL: url, message: error.localizedDescription))
            }
        }
        try Task.checkCancellation()
        cache.entries = retained
        return Catalog(entries: entries.sorted { $0.metadata.startedAt > $1.metadata.startedAt }, issues: issues)
    }

    static func load(_ entry: Entry) throws -> MeetingNote {
        try Task.checkCancellation()
        let bytes = try read(entry)
        guard let text = String(data: bytes, encoding: .utf8),
              var note = MarkdownCodec.decode(text, fileURL: entry.fileURL),
              note.libraryIdentity == entry.identity else { throw Failure.invalidDocument }
        try Task.checkCancellation()
        note.fileRevision = entry.revision
        note.fileModified = entry.modified
        return note
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
