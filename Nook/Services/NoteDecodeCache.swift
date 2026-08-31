import Foundation

/// Reuses decoding only for the same canonical file and exact content bytes.
///
/// Reloads still read bytes off the main actor. Modification dates can survive
/// an external edit, so they cannot establish freshness. Matching a content
/// revision skips the expensive Markdown decoding and transcript cleanup.
final class NoteDecodeCache: @unchecked Sendable {
    private struct Entry {
        let revision: Data
        let note: MeetingNote
    }

    private let lock = NSLock()
    private var entries: [URL: Entry] = [:]

    func note(for url: URL, revision: Data) -> MeetingNote? {
        let key = Self.key(for: url)
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key], entry.revision == revision else {
            return nil
        }
        return entry.note
    }

    func store(_ note: MeetingNote, for url: URL, revision: Data) {
        let key = Self.key(for: url)
        lock.lock()
        defer { lock.unlock() }
        entries[key] = Entry(revision: revision, note: note)
    }

    func prune(keeping urls: [URL]) {
        let retained = Set(urls.map(Self.key(for:)))
        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter { retained.contains($0.key) }
    }

    private static func key(for url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }
}
