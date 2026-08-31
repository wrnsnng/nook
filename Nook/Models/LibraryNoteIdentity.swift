import Foundation

/// A Markdown UUID names the note's lineage, not a unique file: Finder copies
/// keep it. Library rows, search hits, and navigation need the captured path as
/// well so choosing one copy cannot open another. This is not persisted into
/// the document. Foundation may consult the filesystem while standardizing a
/// bridged URL, so MeetingNote captures this value with its file address and
/// reuses it during layout.
struct LibraryNoteIdentity: Hashable, Sendable {
    let noteID: UUID
    let filePath: String?

    init(noteID: UUID, fileURL: URL?) {
        self.noteID = noteID
        self.filePath = fileURL?.standardizedFileURL.path
    }

    var fileURL: URL? { filePath.map { URL(fileURLWithPath: $0) } }

    var navigationKey: String {
        "\(noteID.uuidString):\(filePath ?? "unsaved")"
    }
}

/// UUID-only links from older notifications and citations are safe only when
/// they resolve to one file. Ambiguity becomes a choice, never `first(where:)`.
enum LibraryNoteResolution: Equatable {
    case missing
    case unique(LibraryNoteIdentity)
    case ambiguous

    static func resolve(_ id: UUID, in notes: [MeetingNote]) -> Self {
        let candidates = notes.filter { $0.id == id }
        guard let note = candidates.first else { return .missing }
        guard candidates.count == 1 else { return .ambiguous }
        return .unique(note.libraryIdentity)
    }
}

/// Aggregates cannot decide whether copied UUIDs are another meeting or a
/// conflicting version of one. Keep every copy in the library, but omit the
/// entire ambiguous group before building history, answers, or counts.
enum LibraryNoteAggregation {
    static func partition(_ notes: [MeetingNote]) -> (eligible: [MeetingNote], omitted: [MeetingNote]) {
        let groups = Dictionary(grouping: notes, by: \.id)
        let ambiguousIDs = Set(groups.compactMap { $0.value.count > 1 ? $0.key : nil })
        return (
            notes.filter { !ambiguousIDs.contains($0.id) },
            notes.filter { ambiguousIDs.contains($0.id) }
        )
    }

    static let omissionMessage = "Notes with a shared ID are excluded. Review the copies in your library."
}
