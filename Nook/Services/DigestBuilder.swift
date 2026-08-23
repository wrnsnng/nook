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

    static func build(
        from allNotes: [MeetingNote],
        now: Date = Date(),
        overviewProvider: (@Sendable ([MeetingNote]) async -> String?)? = nil
    ) async -> MeetingNote {
        let window = period(now: now)
        let covered = allNotes
            .filter { $0.kind == .meeting }
            .filter { $0.startedAt >= window.start && $0.startedAt <= window.end }
            .sorted { $0.startedAt < $1.startedAt }

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

        var summary = """
            \(covered.count) meetings between \
            \(window.start.formatted(date: .abbreviated, time: .omitted)) and \
            \(window.end.formatted(date: .abbreviated, time: .omitted)). \
            \(stats.joined(separator: ", ")).
            """
        if let overview = await overviewProvider?(covered),
           !overview.trimmingCharacters(in: .whitespaces).isEmpty {
            summary += "\n\n\(overview.trimmingCharacters(in: .whitespaces))"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let title = "Week of \(formatter.string(from: window.start))"

        return MeetingNote(
            kind: .digest,
            title: title,
            startedAt: window.start,
            endedAt: window.end,
            sourceApp: "Digest",
            summary: summary,
            keyPoints: keyPoints,
            decisions: decisions,
            actionItems: [],
            transcript: []
        )
    }

    /// How much of the week was spent in captured conversation. Uses each
    /// note's sitting-aware duration, so a multi-session meeting counts its
    /// recorded time rather than the span between sittings.
    static func conversationTimeLabel(for seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        if minutes >= 60 {
            let remainder = minutes % 60
            return remainder == 0
                ? "\(minutes / 60)h of conversation"
                : "\(minutes / 60)h \(remainder)m of conversation"
        }
        return "\(minutes)m of conversation"
    }
}
