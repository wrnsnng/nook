import Foundation

enum MarkdownCodec {
    static func encode(_ note: MeetingNote) -> String {
        let keyPoints = checklist(note.keyPoints, checked: nil)
        let decisions = checklist(note.decisions, checked: nil)
        let actions = checklist(note.actionItems, checked: false)
        let personalNotes = note.personalNotes
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let transcript = note.transcript.map {
            let speaker = $0.source == .mixed ? "" : "**\($0.source.label):** "
            return "- **[\($0.timestamp)]** \(speaker)\($0.text.trimmingCharacters(in: .whitespacesAndNewlines))"
        }.joined(separator: "\n")

        return """
        ---
        id: \(note.id.uuidString)
        title: "\(escape(note.title))"
        started: \(isoString(from: note.startedAt))
        ended: \(isoString(from: note.endedAt))
        source: "\(escape(note.sourceApp))"
        ---

        # \(note.title)

        ## Summary

        \(note.summary.trimmingCharacters(in: .whitespacesAndNewlines))

        ## Key points

        \(keyPoints)

        ## Decisions

        \(decisions)

        ## Action items

        \(actions)

        ## My notes

        \(personalNotes.isEmpty ? "_No personal notes._" : personalNotes)

        ## Transcript

        \(transcript.isEmpty ? "_No speech was detected._" : transcript)
        """
    }

    static func decode(_ markdown: String, fileURL: URL? = nil) -> MeetingNote? {
        let metadata = parseFrontmatter(markdown)
        let bodyTitle = firstHeading(in: markdown)
        guard
            let id = UUID(uuidString: metadata["id"] ?? ""),
            let startedAt = isoDate(from: metadata["started"] ?? ""),
            let endedAt = isoDate(from: metadata["ended"] ?? "")
        else {
            return nil
        }

        let title = unquote(metadata["title"] ?? bodyTitle ?? "Untitled meeting")
        let source = unquote(metadata["source"] ?? "Unknown")
        let summary = section("Summary", in: markdown).trimmingCharacters(in: .whitespacesAndNewlines)
        let keyPoints = NoteContentSanitizer.meaningfulItems(
            listItems(in: section("Key points", in: markdown))
        )
        let decisions = NoteContentSanitizer.meaningfulItems(
            listItems(in: section("Decisions", in: markdown))
        )
        let actionItems = NoteContentSanitizer.meaningfulItems(
            listItems(in: section("Action items", in: markdown))
        )
        let personalNotesSection = section("My notes", in: markdown)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let personalNotes = personalNotesSection == "_No personal notes._"
            ? ""
            : personalNotesSection
        let transcript = TranscriptAssembler.coalesce(
            transcriptItems(in: section("Transcript", in: markdown))
        )

        return MeetingNote(
            id: id,
            title: title,
            startedAt: startedAt,
            endedAt: endedAt,
            sourceApp: source,
            summary: summary,
            keyPoints: keyPoints,
            decisions: decisions,
            actionItems: actionItems,
            personalNotes: personalNotes,
            transcript: transcript,
            fileURL: fileURL
        )
    }

    static func section(_ title: String, in markdown: String) -> String {
        let marker = "## \(title)"
        guard let markerRange = markdown.range(of: marker, options: [.caseInsensitive]) else {
            return ""
        }
        let remainder = markdown[markerRange.upperBound...]
        if let next = remainder.range(of: "\n## ") {
            return String(remainder[..<next.lowerBound])
        }
        return String(remainder)
    }

    private static func parseFrontmatter(_ markdown: String) -> [String: String] {
        guard markdown.hasPrefix("---\n") else { return [:] }
        let content = markdown.dropFirst(4)
        guard let end = content.range(of: "\n---") else { return [:] }
        return content[..<end.lowerBound]
            .split(separator: "\n")
            .reduce(into: [String: String]()) { values, line in
                guard let colon = line.firstIndex(of: ":") else { return }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                values[key] = value
            }
    }

    private static func firstHeading(in markdown: String) -> String? {
        markdown.split(separator: "\n")
            .first(where: { $0.hasPrefix("# ") })
            .map { String($0.dropFirst(2)) }
    }

    private static func listItems(in section: String) -> [String] {
        section.split(separator: "\n").compactMap { rawLine in
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- ") else { return nil }
            line.removeFirst(2)
            if line.hasPrefix("[ ] ") || line.hasPrefix("[x] ") || line.hasPrefix("[X] ") {
                line.removeFirst(4)
            }
            return line
        }
    }

    private static func transcriptItems(in section: String) -> [TranscriptSegment] {
        section.split(separator: "\n").compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- **["), let closing = line.range(of: "]**") else { return nil }
            let stampStart = line.index(line.startIndex, offsetBy: 5)
            let stamp = String(line[stampStart..<closing.lowerBound])
            var text = line[closing.upperBound...].trimmingCharacters(in: .whitespaces)
            let source: TranscriptSegment.Source
            if text.hasPrefix("**You:** ") {
                source = .microphone
                text.removeFirst("**You:** ".count)
            } else if text.hasPrefix("**Meeting:** ") {
                source = .system
                text.removeFirst("**Meeting:** ".count)
            } else {
                source = .mixed
            }
            let parts = stamp.split(separator: ":").compactMap { TimeInterval($0) }
            let seconds: TimeInterval
            if parts.count == 3 {
                seconds = parts[0] * 3_600 + parts[1] * 60 + parts[2]
            } else if parts.count == 2 {
                seconds = parts[0] * 60 + parts[1]
            } else {
                seconds = 0
            }
            return TranscriptSegment(
                startTime: seconds,
                duration: 0,
                text: text,
                source: source
            )
        }
    }

    private static func checklist(_ values: [String], checked: Bool?) -> String {
        guard !values.isEmpty else { return "_None captured._" }
        let prefix = checked.map { $0 ? "- [x] " : "- [ ] " } ?? "- "
        return values.map { prefix + $0 }.joined(separator: "\n")
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func unquote(_ value: String) -> String {
        guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else {
            return value
        }
        return String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
    }

    private static func isoString(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func isoDate(from value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}
