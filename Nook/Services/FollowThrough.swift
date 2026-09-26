import Foundation

/// The person an action item belongs to, read from how people already write
/// them: `Maya — refine the copy`, `Maya: refine the copy`, `@Maya refine the
/// copy`, or `Maya will refine the copy`.
///
/// Read-only by design. The note keeps its own wording and nothing is
/// migrated; an item nobody named simply has no owner.
enum ActionItemOwner {
    struct Parsed: Equatable, Sendable {
        let owner: String?
        /// The item without the owner prefix, for when the owner is shown
        /// separately. Unchanged when there is no owner.
        let task: String

        /// The task as a row shows it beside its owner: "Maya — refine the
        /// copy" reads as "Refine the copy". Display only; the note keeps its
        /// own wording.
        var displayTask: String {
            guard owner != nil, let first = task.first else { return task }
            return first.uppercased() + task.dropFirst()
        }
    }

    static func parse(_ text: String) -> Parsed {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("@") {
            let body = trimmed.dropFirst()
            let name = body.prefix { $0.isLetter || $0 == "." || $0 == "-" || $0 == "'" }
            let rest = body.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !rest.isEmpty {
                return Parsed(owner: String(name), task: rest)
            }
        }

        // Written as escapes: these match what people type (em and en
        // dashes included), they are never shown, and the interface copy
        // rule forbids em-dashes in Nook's own strings.
        for separator in [" \u{2014} ", " \u{2013} ", " - ", ": "] {
            guard let range = trimmed.range(of: separator) else { continue }
            let candidate = String(trimmed[..<range.lowerBound])
            let rest = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if isName(candidate), !rest.isEmpty {
                return Parsed(owner: candidate, task: rest)
            }
        }

        // "Maya will send the brief": a single name, then "will". Kept
        // narrow on purpose; a capitalised verb such as "Send" never
        // precedes "will", and pronouns are refused below.
        let words = trimmed.split(separator: " ", maxSplits: 2).map(String.init)
        if words.count == 3, words[1] == "will", isName(words[0]) {
            return Parsed(owner: words[0], task: words[2])
        }

        return Parsed(owner: nil, task: trimmed)
    }

    /// One to three capitalised words, short enough to be a name, and not a
    /// label people put in front of items ("TODO:", "Note:", "Next:").
    static func isName(_ candidate: String) -> Bool {
        let words = candidate.split(separator: " ")
        guard
            (1...3).contains(words.count),
            candidate.count <= 32,
            !notNames.contains(candidate.lowercased())
        else {
            return false
        }
        return words.allSatisfy { word in
            guard let first = word.first, first.isUppercase else { return false }
            return word.allSatisfy { $0.isLetter || $0 == "." || $0 == "-" || $0 == "'" }
        }
    }

    private static let notNames: Set<String> = [
        "todo", "to do", "note", "notes", "action", "actions", "action item",
        "next", "next step", "next steps", "follow up", "follow-up", "fyi",
        "decision", "question", "update", "owner", "task", "reminder",
        "important", "urgent", "blocked", "done", "we", "i", "they", "you",
        "someone", "nobody", "he", "she", "it", "this", "that"
    ]
}

/// A recap of a saved meeting, written from the note's own sections.
///
/// Deterministic, so it exists whether or not a language model is available,
/// and nothing in it can be more certain than the note it came from. Nook
/// never sends it; the user reviews it in Mail or wherever they paste it.
enum FollowUpDraft {
    enum Format: String, CaseIterable, Identifiable, Sendable {
        case email
        case chat

        var id: Self { self }

        var label: String {
            switch self {
            case .email: "Email"
            case .chat: "Chat"
            }
        }
    }

    struct Draft: Equatable, Sendable {
        let subject: String
        let body: String
    }

    static func make(from note: MeetingNote, format: Format) -> Draft {
        let subject = "Recap: \(note.title)"
        let summary = leadParagraph(of: note.summary)
        let decisions = note.decisions.map(cleaned).filter { !$0.isEmpty }
        let nextSteps = note.actionItems
            .filter { !note.completedActionItems.contains($0) }
            .map(nextStep)
            .filter { !$0.isEmpty }
        let questions = note.openQuestions.map(cleaned).filter { !$0.isEmpty }

        var sections: [String] = []
        switch format {
        case .email:
            sections.append("Hi all,")
            sections.append("Thanks for the time today. Here is a short recap of \(note.title).")
            if !summary.isEmpty { sections.append(summary) }
            if !decisions.isEmpty { sections.append(list("Decisions", decisions)) }
            if !nextSteps.isEmpty { sections.append(list("Next steps", nextSteps)) }
            if !questions.isEmpty { sections.append(list("Still open", questions)) }
            sections.append("Let me know if I missed anything.")
        case .chat:
            sections.append("*\(subject)*" + (summary.isEmpty ? "" : "\n" + summary))
            if !decisions.isEmpty { sections.append(list("*Decisions*", decisions)) }
            if !nextSteps.isEmpty { sections.append(list("*Next steps*", nextSteps)) }
            if !questions.isEmpty { sections.append(list("*Still open*", questions)) }
        }
        return Draft(subject: subject, body: sections.joined(separator: "\n\n"))
    }

    /// "Maya: refine the copy (due Sep 30)", so owners and dates read at a
    /// glance in a recap.
    static func nextStep(_ item: String) -> String {
        let due = ActionItemLine.dueDate(in: item)
        let parsed = ActionItemOwner.parse(cleaned(ActionItemLine.strippingDueSuffix(from: item)))
        guard !parsed.task.isEmpty else { return "" }
        var line = parsed.owner.map { "\($0): \(parsed.task)" } ?? parsed.task
        if let due {
            line += " (due \(due.formatted(.dateTime.month(.abbreviated).day())))"
        }
        return line
    }

    private static func list(_ heading: String, _ items: [String]) -> String {
        ([heading] + items.map { "• \($0)" }).joined(separator: "\n")
    }

    /// The first paragraph of the summary: a recap leads with the gist, the
    /// rest is in the note for anyone who wants it.
    private static func leadParagraph(of summary: String) -> String {
        summary
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    private static func cleaned(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
