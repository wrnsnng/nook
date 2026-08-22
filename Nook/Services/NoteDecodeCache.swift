import Foundation

/// A decode cache keyed by file modification date.
///
/// Every app activation used to re-read and re-decode every Markdown file,
/// regex-cleaning whole transcripts each time, even when nothing on disk had
/// changed. Entries survive only while their file's timestamp matches, so an
/// edit through any route invalidates itself.
final class NoteDecodeCache: @unchecked Sendable {
    private struct Entry {
        let modified: Date
        let note: MeetingNote
    }

    private let lock = NSLock()
    private var entries: [URL: Entry] = [:]

    func note(for url: URL, modified: Date) -> MeetingNote? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[url], entry.modified == modified else {
            return nil
        }
        return entry.note
    }

    func store(_ note: MeetingNote, for url: URL, modified: Date) {
        lock.lock()
        defer { lock.unlock() }
        entries[url] = Entry(modified: modified, note: note)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }
}
