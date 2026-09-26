import AppIntents
import Foundation

/// A saved note, as Shortcuts and Siri can name and pass it around.
///
/// Identified by the note's Markdown UUID, the same identifier Spotlight and
/// notification links use, because it survives a rename that moves the file.
/// Copies sharing a UUID are left out: the identifier cannot say which copy
/// was meant, and the library asks the user to review them instead.
struct MeetingEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Meeting"
    static let defaultQuery = MeetingEntityQuery()

    let id: UUID
    let title: String
    let startedAt: Date
    let kind: NoteKind

    init(note: MeetingNote) {
        id = note.id
        title = note.title
        startedAt = note.startedAt
        kind = note.kind
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(subtitle)",
            image: DisplayRepresentation.Image(systemName: kind.symbol)
        )
    }

    /// The date, and what the note is when it is not a recorded meeting, so
    /// two notes with one title can still be told apart in a list.
    private var subtitle: String {
        let date = startedAt.formatted(date: .abbreviated, time: .shortened)
        return kind == .meeting ? date : "\(kind.label), \(date)"
    }
}

struct MeetingEntityQuery: EntityStringQuery {
    /// Enough recent notes to choose from without listing a whole library.
    static let suggestionLimit = 20
    static let searchLimit = 50

    func entities(for identifiers: [MeetingEntity.ID]) async throws -> [MeetingEntity] {
        let notes = await Self.libraryNotes()
        return Self.notes(withIDs: identifiers, in: notes).map(MeetingEntity.init)
    }

    func entities(matching string: String) async throws -> [MeetingEntity] {
        let notes = await Self.libraryNotes()
        return Self.matching(string, in: notes).map(MeetingEntity.init)
    }

    func suggestedEntities() async throws -> [MeetingEntity] {
        let notes = await Self.libraryNotes()
        return Self.matching("", in: notes, limit: Self.suggestionLimit)
            .map(MeetingEntity.init)
    }

    @MainActor
    private static func libraryNotes() async -> [MeetingNote] {
        let store = AppModel.shared.store
        await waitForLibraryToLoad(store)
        return store.notes
    }

    /// Notes whose titles contain every word of `query`, newest first.
    ///
    /// Uses the library search's own term matching, so a title Shortcuts
    /// finds is one the library's search field would find too. An empty
    /// query lists the most recent notes.
    static func matching(
        _ query: String,
        in notes: [MeetingNote],
        limit: Int = searchLimit
    ) -> [MeetingNote] {
        let terms = query
            .split(whereSeparator: \.isWhitespace)
            .map { LibrarySearchTerm(String($0).localizedLowercase) }
        return LibraryNoteAggregation.partition(notes).eligible
            .filter { note in
                let title = note.title.localizedLowercase
                return terms.allSatisfy { $0.matches(in: title) }
            }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(limit)
            .map { $0 }
    }

    /// The notes a saved Shortcut refers to, in the order it asked for them.
    /// An identifier that is missing or now shared by copies resolves to
    /// nothing rather than to whichever copy happens to come first.
    static func notes(withIDs identifiers: [UUID], in notes: [MeetingNote]) -> [MeetingNote] {
        let byID = Dictionary(
            LibraryNoteAggregation.partition(notes).eligible.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return identifiers.compactMap { byID[$0] }
    }
}
