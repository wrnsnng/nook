import Foundation

/// Compiles several notes into one weekly digest note.
///
/// Aggregation is deterministic so a digest never invents outcomes; the only
/// model-written part is an optional overview paragraph, and the digest is
/// complete and honest without it.
enum DigestBuilder {
    /// The window the library's "Create weekly digest" action covers: the
    /// seven days ending now, inclusive of today's meetings.
    static func period(now: Date = Date()) -> (start: Date, end: Date) {
        (now.addingTimeInterval(-7 * 24 * 3_600), now)
    }

    /// The meetings one digest for `now`'s window would cover. Exposed
    /// separately so a caller deciding whether there is anything to compile
    /// does not need its own copy of this filter.
    static func coveredMeetings(
        from allNotes: [MeetingNote],
        now: Date = Date()
    ) -> [MeetingNote] {
        let window = period(now: now)
        return LibraryNoteAggregation.partition(allNotes).eligible
            .filter { $0.kind == .meeting }
            .filter { $0.startedAt >= window.start && $0.startedAt <= window.end }
            .sorted { $0.startedAt < $1.startedAt }
    }

    static func omittedMeetingCount(from allNotes: [MeetingNote], now: Date = Date()) -> Int {
        let window = period(now: now)
        return LibraryNoteAggregation.partition(allNotes).omitted.filter {
            $0.kind == .meeting && $0.startedAt >= window.start && $0.startedAt <= window.end
        }.count
    }

    /// An update has no explicit file choice. A duplicated candidate must
    /// therefore be reviewed before one copy can become the weekly digest.
    static func replacement(in notes: [MeetingNote], now: Date = Date()) throws -> MeetingNote? {
        let window = period(now: now)
        let candidates = notes.filter {
            $0.kind == .digest && $0.startedAt >= window.start && $0.startedAt <= window.end
        }
        let omittedIDs = Set(LibraryNoteAggregation.partition(notes).omitted.map(\.id))
        guard !candidates.contains(where: { omittedIDs.contains($0.id) }) else {
            throw DigestBuildError.ambiguousReplacement
        }
        return candidates.first
    }

    /// Compiling can suspend. Never turn a previous target into permission to
    /// update another copy, nor a previous absence into a second new digest.
    static func validateReplacement(
        _ original: MeetingNote?,
        in notes: [MeetingNote],
        now: Date
    ) throws {
        let current = try replacement(in: notes, now: now)
        guard current?.libraryIdentity == original?.libraryIdentity,
              current?.fileRevision == original?.fileRevision else {
            throw DigestBuildError.changedReplacement
        }
    }

    static func build(
        from allNotes: [MeetingNote],
        now: Date = Date(),
        id: UUID = UUID(),
        fileURL: URL? = nil,
        replacing existing: MeetingNote? = nil,
        overviewProvider: (@Sendable ([MeetingNote]) async -> String?)? = nil
    ) async -> MeetingNote {
        let window = period(now: now)
        let covered = coveredMeetings(from: allNotes, now: now)

        var decisions: [String] = []
        for note in covered {
            for decision in note.decisions where !decisions.contains(decision) {
                decisions.append(decision)
            }
        }

        // Two highlights per meeting keeps a busy week readable while every
        // meeting stays represented.
        var keyPoints: [String] = []
        for note in covered {
            for point in note.keyPoints.prefix(2) {
                let labelled = "\(note.title): \(point)"
                if !keyPoints.contains(labelled) {
                    keyPoints.append(labelled)
                }
            }
        }

        let flaggedCount = covered.reduce(0) { $0 + $1.moments.count }
        let conversationSeconds = covered.reduce(0) { $0 + $1.duration }
        var stats = [
            covered.count == 1
                ? "1 meeting captured"
                : "\(covered.count) meetings captured",
            Self.conversationTimeLabel(for: conversationSeconds),
        ]
        if flaggedCount > 0 {
            stats.append(
                flaggedCount == 1
                    ? "1 moment flagged"
                    : "\(flaggedCount) moments flagged"
            )
        }

        let meetingCountLabel = covered.count == 1
            ? "1 meeting"
            : "\(covered.count) meetings"
        var summary = """
            \(meetingCountLabel) between \
            \(window.start.formatted(date: .abbreviated, time: .omitted)) and \
            \(window.end.formatted(date: .abbreviated, time: .omitted)). \
            \(stats.joined(separator: ", ")).
            """
        if omittedMeetingCount(from: allNotes, now: now) > 0 {
            summary += "\n\n" + LibraryNoteAggregation.omissionMessage
        }
        if let overview = await overviewProvider?(covered),
           !overview.trimmingCharacters(in: .whitespaces).isEmpty {
            summary += "\n\n\(overview.trimmingCharacters(in: .whitespaces))"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let title = "Week of \(formatter.string(from: window.start))"

        // A compiled update owns its overview and extracted outcomes, not
        // the user's title, annotations, tasks or file revision. Keeping the
        // original snapshot also makes an external edit during compilation
        // a save conflict rather than permission to overwrite the newer file.
        var digest = existing ?? MeetingNote(
            id: id,
            kind: .digest,
            title: title,
            startedAt: window.start,
            endedAt: window.end,
            sourceApp: "Digest",
            summary: summary,
            keyPoints: keyPoints,
            decisions: decisions,
            actionItems: [],
            transcript: [],
            fileURL: fileURL
        )
        digest.startedAt = window.start
        digest.endedAt = window.end
        digest.summary = summary
        digest.keyPoints = keyPoints
        digest.decisions = decisions
        return digest
    }

    /// How much of the week was spent in captured conversation. Uses each
    /// note's sitting-aware duration, so a multi-session meeting counts its
    /// recorded time rather than the span between sittings.
    static func conversationTimeLabel(for seconds: TimeInterval) -> String {
        "\(NookElapsedTime.minutes(seconds)) of conversation"
    }
}

enum DigestBuildError: LocalizedError, Equatable {
    case ambiguousReplacement
    case changedReplacement

    var errorDescription: String? {
        switch self {
        case .ambiguousReplacement:
            "The weekly digest has copies with a shared ID. Review the copies in your library before updating it."
        case .changedReplacement:
            "The library or weekly digest changed while it was being compiled. Review it and try again."
        }
    }
}
