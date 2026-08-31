import Combine
import Foundation

/// Recognizes which saved notes belong to the same recurring event.
///
/// Calendar frameworks do not expose a stable identifier that survives
/// across occurrences of a recurrence in a form notes can carry, so series
/// membership is decided by normalized title. Titles are stripped of the
/// parts that change between occurrences (dates, times, cadence words,
/// connective grammar), leaving the phrase people actually call the series.
enum SeriesMatcher {
    /// Tokens that describe when a meeting happens rather than what it is.
    private static let droppedTokens: Set<String> = [
        "the", "a", "an", "of", "for", "and", "or", "with", "to", "at",
        "in", "on", "by",
        "am", "pm",
        "week", "weeks", "weekly", "biweekly", "daily", "monthly",
        "month", "months", "year", "years", "today", "tomorrow",
        "monday", "tuesday", "wednesday", "thursday", "friday",
        "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept",
        "oct", "nov", "dec",
    ]

    /// A stable, comparable identity for an event or note title.
    static func seriesKey(for title: String) -> String {
        // Times are stripped before tokenizing so "10am" cannot survive as
        // part of an identity; bare numbers are dropped below anyway.
        let withoutTimes = title
            .replacingOccurrences(
                of: #"\d{1,2}:\d{2}"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\d{1,2}\s*(am|pm)"#,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        return withoutTimes.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .filter { !($0.allSatisfy(\.isNumber)) }
            .filter { !droppedTokens.contains(String($0)) }
            .joined(separator: " ")
    }

    /// Whether a note belongs to the same series as an event title.
    static func matches(noteTitle: String, eventTitle: String) -> Bool {
        let noteKey = seriesKey(for: noteTitle)
        guard !noteKey.isEmpty else { return false }
        return noteKey == seriesKey(for: eventTitle)
    }
}

/// What is known about the next occurrence of a series the user has met
/// before, assembled entirely from their own saved notes.
struct PrepBrief: Identifiable, Hashable, Sendable {
    struct ActionItemRef: Hashable, Sendable {
        let noteID: MeetingNote.ID
        let noteTitle: String
        let text: String
    }

    let seriesKey: String
    let eventTitle: String
    let startDate: Date
    /// Matching notes, most recent sitting first.
    let sittings: [MeetingNote]
    /// Matching copies stay available for review, without becoming history.
    let omittedNoteCount: Int

    var id: String { seriesKey }

    /// This event continues the series, so it is the next number.
    var upcomingSittingNumber: Int { sittings.count + 1 }

    var lastMetAt: Date? {
        sittings.first?.startedAt
    }

    var totalDuration: TimeInterval {
        sittings.reduce(0) { $0 + $1.duration }
    }

    var lastKeyPoints: [String] {
        sittings.first?.keyPoints ?? []
    }

    var lastDecisions: [String] {
        sittings.first?.decisions ?? []
    }

    /// Every action item the series' notes mention, oldest sitting first.
    ///
    /// Whether each item is finished lives in the checkbox state of its own
    /// file and is tracked in the library's open-actions list; a brief names
    /// what was written without claiming what remains open.
    var mentionedActions: [ActionItemRef] {
        sittings.reversed().flatMap { note in
            note.actionItems.map { item in
                ActionItemRef(
                    noteID: note.id,
                    noteTitle: note.title,
                    text: item
                )
            }
        }
    }
}

/// Assembles prep briefs deterministically from the local library.
///
/// No model call sits anywhere in this path: a brief quotes the notes, it
/// never paraphrases them, so it cannot invent history before an important
/// meeting.
enum PrepBriefBuilder {
    /// The brief for an upcoming event, or nil when the library holds no
    /// earlier sitting of that series.
    ///
    /// `noteSeriesKeys` lets a caller that already knows each note's series
    /// key (see `SeriesKeyCache`) skip recomputing it here; without one,
    /// every note's title is run through the matcher's regular expressions
    /// on this call, exactly as before.
    static func build(
        eventTitle: String,
        startDate: Date,
        notes: [MeetingNote],
        noteSeriesKeys: [MeetingNote.ID: String]? = nil
    ) -> PrepBrief? {
        // Computed once here rather than once per note, as `matches` used to
        // do internally on every call.
        let key = SeriesMatcher.seriesKey(for: eventTitle)
        guard !key.isEmpty else { return nil }
        let partition = LibraryNoteAggregation.partition(notes)
        let omittedNoteCount = partition.omitted.filter {
            $0.kind != .digest && SeriesMatcher.seriesKey(for: $0.title) == key
        }.count
        let sittings = partition.eligible
            .filter { note in
                guard note.kind != .digest else { return false }
                let noteKey = noteSeriesKeys?[note.id]
                    ?? SeriesMatcher.seriesKey(for: note.title)
                return !noteKey.isEmpty && noteKey == key
            }
            .sorted { $0.startedAt > $1.startedAt }
        // All history may be ambiguous. Keep a warning surface instead of
        // silently suggesting this meeting has never happened before.
        guard !sittings.isEmpty || omittedNoteCount > 0 else { return nil }
        return PrepBrief(
            seriesKey: key,
            eventTitle: eventTitle,
            startDate: startDate,
            sittings: sittings,
            omittedNoteCount: omittedNoteCount
        )
    }
}

/// Caches each note's series key by id and title, so a title that has not
/// changed since the last `store.notes` publish is not re-parsed through
/// `SeriesMatcher`'s regular expressions again. An actor because it is
/// populated from a detached task, off the main actor, on every publish.
actor SeriesKeyCache {
    private var entries: [MeetingNote.ID: (title: String, key: String)] = [:]

    /// Every note's series key, computed fresh only for notes that are new
    /// or whose title changed since the last call.
    func keys(for notes: [MeetingNote]) -> [MeetingNote.ID: String] {
        let eligible = LibraryNoteAggregation.partition(notes).eligible
        var result: [MeetingNote.ID: String] = [:]
        result.reserveCapacity(eligible.count)
        for note in eligible {
            if let cached = entries[note.id], cached.title == note.title {
                result[note.id] = cached.key
            } else {
                let key = SeriesMatcher.seriesKey(for: note.title)
                entries[note.id] = (note.title, key)
                result[note.id] = key
            }
        }
        // Notes no longer in the library have nothing left to reuse their
        // entry, so drop it rather than growing this forever.
        let currentIDs = Set(eligible.map(\.id))
        entries = entries.filter { currentIDs.contains($0.key) }
        return result
    }
}

/// Owns the brief for whatever calendar event is currently approaching, so
/// the library can show a quiet prep surface without polling anything.
@MainActor
final class PrepBriefController: ObservableObject {
    @Published private(set) var current: PrepBrief?

    private var cancellables: Set<AnyCancellable> = []
    private let seriesKeyCache = SeriesKeyCache()
    /// Guards against an older publish's detached build finishing after a
    /// newer one and overwriting it with stale history.
    private var buildGeneration = 0

    init(store: MarkdownStore, calendar: CalendarContextService) {
        Publishers.CombineLatest(
            calendar.$currentUpcomingEvent.removeDuplicates(),
            store.$notes
        )
        .sink { [weak self, seriesKeyCache] event, notes in
            guard let self else { return }
            guard let event else {
                buildGeneration += 1
                // Invalidate a pending build even if no brief is visible,
                // but do not redraw the Library for an unchanged absence.
                if current != nil { current = nil }
                return
            }
            buildGeneration += 1
            let generation = buildGeneration
            // Keying every note's title against the series matcher's
            // regular expressions is real work once a library holds
            // hundreds of notes, and `store.notes` can publish on every
            // save across the whole app; do it off the main actor.
            Task.detached(priority: .utility) {
                let noteSeriesKeys = await seriesKeyCache.keys(for: notes)
                let brief = PrepBriefBuilder.build(
                    eventTitle: event.title,
                    startDate: event.startDate,
                    notes: notes,
                    noteSeriesKeys: noteSeriesKeys
                )
                await MainActor.run { [weak self] in
                    guard let self, self.buildGeneration == generation
                    else { return }
                    self.current = brief
                }
            }
        }
        .store(in: &cancellables)
    }
}
