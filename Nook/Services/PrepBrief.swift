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
    static func build(
        eventTitle: String,
        startDate: Date,
        notes: [MeetingNote]
    ) -> PrepBrief? {
        let key = SeriesMatcher.seriesKey(for: eventTitle)
        guard !key.isEmpty else { return nil }
        let sittings = notes
            .filter {
                $0.kind != .digest && SeriesMatcher.matches(
                    noteTitle: $0.title,
                    eventTitle: eventTitle
                )
            }
            .sorted { $0.startedAt > $1.startedAt }
        guard !sittings.isEmpty else { return nil }
        return PrepBrief(
            seriesKey: key,
            eventTitle: eventTitle,
            startDate: startDate,
            sittings: sittings
        )
    }
}

/// Owns the brief for whatever calendar event is currently approaching, so
/// the library can show a quiet prep surface without polling anything.
@MainActor
final class PrepBriefController: ObservableObject {
    @Published private(set) var current: PrepBrief?

    private var cancellables: Set<AnyCancellable> = []

    init(store: MarkdownStore, calendar: CalendarContextService) {
        Publishers.CombineLatest(
            calendar.$currentUpcomingEvent.removeDuplicates(),
            store.$notes
        )
        .sink { [weak self] event, notes in
            guard let self else { return }
            guard let event else {
                current = nil
                return
            }
            current = PrepBriefBuilder.build(
                eventTitle: event.title,
                startDate: event.startDate,
                notes: notes
            )
        }
        .store(in: &cancellables)
    }
}
