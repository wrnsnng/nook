import Foundation

/// Early, read-only discovery. The store still publishes complete notes as one
/// snapshot for editing, summaries and every other full-content consumer.
enum LibraryDiscovery {
    struct Entry: Hashable, Identifiable, Sendable {
        var id: LibraryNoteIdentity { identity }
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

    enum Failure: LocalizedError {
        case invalidDocument, sourceChanged
        var errorDescription: String? {
            switch self {
            case .invalidDocument: "This note could not be read. Retry loading the library."
            case .sourceChanged: "This note changed while the library was loading. Retry to read its current contents."
            }
        }
    }

    static func scan(_ directory: URL) throws -> Catalog {
        var cache = Cache()
        return try scan(directory, cache: &cache)
    }

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
                let entry = try autoreleasepool { () throws -> Entry in
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
                    return entry
                }
                entries.append(entry)
                retained[url.standardizedFileURL] = entry
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

}
