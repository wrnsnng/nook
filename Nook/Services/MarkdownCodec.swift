import Foundation

enum MarkdownCodec {
    static func encode(_ note: MeetingNote) -> String {
        let keyPoints = checklist(note.keyPoints, checked: nil)
        let decisions = checklist(note.decisions, checked: nil)
        let actions = checklist(note.actionItems, checked: false)
        let personalNotes = note.personalNotes
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let transcript = transcriptLines(for: note)

        var frontmatterLines = [
            "---",
            "id: \(note.id.uuidString)",
            "kind: \(note.kind.rawValue)",
            "title: \"\(escape(note.title))\"",
            "started: \(isoString(from: note.startedAt))",
            "ended: \(isoString(from: note.endedAt))",
            "source: \"\(escape(note.sourceApp))\"",
        ]
        if !note.moments.isEmpty {
            // Offsets are rounded to a tenth of a second, which is finer than
            // anyone can flag and keeps the line short for hour-long meetings.
            let offsets = note.moments
                .map { String(format: "%.1f", $0.offset) }
                .joined(separator: ",")
            frontmatterLines.append("moments: \(offsets)")
        }
        // A single-sitting note is the ordinary case, so its sessions stay
        // out of the file entirely.
        if note.sessions.count > 1 {
            let pairs = note.sessions.map { session in
                "\(isoString(from: session.startedAt))/\(isoString(from: session.endedAt))"
            }
            frontmatterLines.append("sessions: \(pairs.joined(separator: ";"))")
        }
        if note.audioStart > 0 {
            frontmatterLines.append(
                "audioStart: \(String(format: "%.1f", note.audioStart))"
            )
        }
        let frontmatter = (frontmatterLines + ["---"]).joined(separator: "\n")

        // A spoken note is a title and then prose, with nothing after it.
        //
        // This is a correctness requirement, not a layout preference. The body
        // is free text: the speaker can dictate a heading, and an assistant
        // action appends its result under one. Any section that followed the
        // body would be found by whichever "## " appeared first, so a heading
        // inside the note would swallow everything written after it. Ending the
        // file with the body makes that impossible rather than unlikely.
        //
        // Nothing is lost by it. Action items and personal notes for a spoken
        // note live in the prose, which is where they were spoken or written.
        if note.kind == .spoken {
            return """
            \(frontmatter)

            # \(headingText(note.title))

            \(note.summary.trimmingCharacters(in: .whitespacesAndNewlines))
            """
        }

        // A digest is compiled, not recorded: it carries the period's
        // overview and outcomes but no transcript and no personal notes.
        if note.kind == .digest {
            return """
            \(frontmatter)

            # \(headingText(note.title))

            ## Summary

            \(note.summary.trimmingCharacters(in: .whitespacesAndNewlines))

            ## Key points

            \(keyPoints)

            ## Decisions

            \(decisions)

            ## Action items

            \(actions)
            """
        }

        return """
        \(frontmatter)

        # \(headingText(note.title))

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
        // Absent in every note written before spoken notes existed, which are
        // all meetings.
        let kind = metadata["kind"]
            .flatMap { NoteKind(rawValue: unquote($0)) } ?? .default
        // A spoken note carries its text under the heading rather than under a
        // "## Summary" marker, so it is read back from the body.
        let summary = kind == .spoken
            ? bodyText(in: markdown)
            : section("Summary", in: markdown)
                .trimmingCharacters(in: .whitespacesAndNewlines)

        // Everything in a spoken note is its prose. Parsing sections out of it
        // would pull fragments of the body into fields that then get written
        // back a second time, duplicating what the user wrote.
        if kind == .spoken {
            return MeetingNote(
                id: id,
                kind: .spoken,
                title: title,
                startedAt: startedAt,
                endedAt: endedAt,
                sourceApp: source,
                summary: summary,
                fileURL: fileURL
            )
        }
        let keyPoints = NoteContentSanitizer.meaningfulItems(
            listItems(in: section("Key points", in: markdown))
        )
        let decisions = NoteContentSanitizer.meaningfulItems(
            listItems(in: section("Decisions", in: markdown))
        )
        let actionItems = NoteContentSanitizer.meaningfulItems(
            listItems(in: section("Action items", in: markdown))
        )
        let personalNotes = personalNotesContent(in: markdown)
        let transcript = TranscriptAssembler.coalesce(
            transcriptItems(in: section("Transcript", in: markdown))
        )
        // Flagged moments only describe a recording timeline, which spoken
        // notes do not have.
        let moments = kind == .spoken
            ? []
            : parseMoments(metadata["moments"] ?? "")
        // Recorded sittings and the audio position exist only on notes that
        // gained a second sitting; every older file decodes without them.
        let sessions = kind == .spoken
            ? []
            : parseSessions(metadata["sessions"] ?? "")
        let audioStart = kind == .spoken
            ? 0
            : TimeInterval(metadata["audioStart"] ?? "") ?? 0

        return MeetingNote(
            id: id,
            kind: kind,
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
            moments: moments,
            sessions: sessions,
            audioStart: audioStart,
            fileURL: fileURL
        )
    }

    /// Flagged offsets from the frontmatter line, in the order written.
    private static func parseMoments(_ value: String) -> [MeetingMoment] {
        value.split(separator: ",").compactMap { piece in
            let offset = TimeInterval(
                piece.trimmingCharacters(in: .whitespaces)
            )
            guard let offset, offset >= 0 else { return nil }
            return MeetingMoment(offset: offset)
        }
    }

    /// Recorded sittings from the frontmatter line.
    private static func parseSessions(_ value: String) -> [MeetingSession] {
        value.split(separator: ";").compactMap { piece in
            let bounds = piece.split(separator: "/")
            guard bounds.count == 2,
                let startedAt = isoDate(from: String(bounds[0])),
                let endedAt = isoDate(from: String(bounds[1]))
            else { return nil }
            return MeetingSession(startedAt: startedAt, endedAt: endedAt)
        }
    }

    /// Transcript lines with a readable divider where one sitting ends and a
    /// later one begins.
    ///
    /// The divider is derived from the sessions list rather than stored as
    /// content, so it can never contradict the frontmatter and a decoder is
    /// free to ignore it. Placement walks cumulative session durations, which
    /// are exactly the offsets appended material was shifted by.
    private static func transcriptLines(for note: MeetingNote) -> String {
        var lines = note.transcript.map { segment in
            let speaker = segment.source == .mixed
                ? "" : "**\(segment.source.label):** "
            return "- **[\(segment.timestamp)]** \(speaker)\(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        guard note.sessions.count > 1 else {
            return lines.joined(separator: "\n")
        }

        var boundary = note.sessions[0].duration
        for session in note.sessions.dropFirst() {
            let divider = "- *(resumed \(sessionResumeStamp(session.startedAt)))*"
            // First segment at or after the boundary opens this sitting; a
            // silent sitting still gets its divider so the file shows where
            // time passed even when nothing was said.
            let insertion = lines.firstIndex {
                guard let offset = segmentOffset($0) else { return false }
                return offset >= boundary - 0.001
            } ?? lines.count
            lines.insert(divider, at: insertion)
            boundary += session.duration
        }
        return lines.joined(separator: "\n")
    }

    /// The timeline offset encoded in a rendered transcript line, or nil for
    /// divider lines.
    private static func segmentOffset(_ line: String) -> TimeInterval? {
        guard line.hasPrefix("- **["), let closing = line.range(of: "]**") else {
            return nil
        }
        let stampStart = line.index(line.startIndex, offsetBy: 5)
        let stamp = String(line[stampStart..<closing.lowerBound])
        let parts = stamp.split(separator: ":").compactMap { TimeInterval($0) }
        switch parts.count {
        case 3: return parts[0] * 3_600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        default: return nil
        }
    }

    private static func sessionResumeStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        return formatter.string(from: date)
    }

    /// The section headings Nook itself writes. Anything else that looks like
    /// a heading belongs to whoever typed it.
    static let recognizedHeadings: Set<String> = [
        "## summary",
        "## key points",
        "## decisions",
        "## action items",
        "## my notes",
        "## transcript"
    ]
}

/// One checkbox item from a note's Action items section, addressed by its
/// position among that section's items so a toggle can edit exactly one line
/// of the file instead of re-encoding the whole document.
struct ActionItemLine: Hashable, Sendable {
    /// The full stored text, including any `[due: ...]` suffix. Toggling
    /// matches on this, so a rewrite can never lose the suffix.
    let index: Int
    let text: String
    let isChecked: Bool

    /// The optional due date carried as a human-readable suffix in the line,
    /// e.g. `- [ ] Draft the note [due: 2026-09-12]`.
    var dueDate: Date? {
        Self.dueDate(in: text)
    }

    /// The text with its due suffix removed, for display and for rewriting
    /// when the date changes.
    var displayText: String {
        Self.strippingDueSuffix(from: text)
    }

    static func dueDate(in text: String) -> Date? {
        guard let range = text.range(of: Self.duePattern, options: .regularExpression)
        else { return nil }
        let stamp = String(text[range])
            .replacingOccurrences(of: "[due:", with: "")
            .replacingOccurrences(of: "]", with: "")
            .trimmingCharacters(in: .whitespaces)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter.date(from: stamp)
    }

    static func strippingDueSuffix(from text: String) -> String {
        var result = text.replacingOccurrences(
            of: duePattern,
            with: "",
            options: .regularExpression,
            range: nil
        )
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static let duePattern = #"\s*\[due:\s*\d{4}-\d{2}-\d{2}\]\s*"#
}

extension MarkdownCodec {
    private static func isHeadingLine(
        _ line: some StringProtocol,
        _ title: String
    ) -> Bool {
        line.trimmingCharacters(in: .whitespaces).lowercased()
            == "## \(title)"
    }

    /// The checkbox items under the Action items heading, in file order.
    ///
    /// Only genuine checkbox lines count; placeholder text such as
    /// "_None captured._" produces nothing rather than an untogglable entry.
    static func actionItemLines(in markdown: String) -> [ActionItemLine] {
        let lines = markdown.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        guard
            let headingIndex = lines.firstIndex(where: {
                isHeadingLine($0, "action items")
            })
        else {
            return []
        }

        var items: [ActionItemLine] = []
        for line in lines[lines.index(after: headingIndex)...] {
            if MarkdownCodec.recognizedHeadings.contains(
                line.trimmingCharacters(in: .whitespaces)
                    .lowercased()
            ) {
                break
            }
            guard let box = checkbox(in: line) else { continue }
            items.append(
                ActionItemLine(
                    index: items.count,
                    text: box.text,
                    isChecked: box.isChecked
                )
            )
        }
        return items
    }

    /// Rewrites exactly one checkbox in the document, leaving every other
    /// byte untouched.
    ///
    /// Decoding and re-encoding would work too, but it normalises whitespace
    /// across every section and would silently rewrite files the user may be
    /// editing elsewhere. Returns nil when the heading or the item has moved,
    /// which callers treat as staleness rather than loss.
    static func markdownBySettingActionItem(
        _ target: ActionItemLine,
        checked: Bool,
        in markdown: String
    ) -> String? {
        let lines = markdown.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard
            let headingIndex = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces)
                    .lowercased() == "## action items"
            }),
            lines.indices.contains(headingIndex)
        else {
            return nil
        }

        var ordinal = -1
        for position in lines.index(after: headingIndex)..<lines.count {
            let line = lines[position]
            if MarkdownCodec.recognizedHeadings.contains(
                line.trimmingCharacters(in: .whitespaces)
            ) {
                break
            }
            guard let box = checkbox(in: line[...]) else { continue }
            ordinal += 1
            guard ordinal == target.index else { continue }
            guard box.text == target.text else { return nil }

            let leading = String(line.prefix(
                while: { $0 == " " || $0 == "\t" }
            ))
            let rewritten = leading + "- [\(checked ? "x" : " ")] \(box.text)"
            var result = lines
            result[position] = rewritten
            return result.joined(separator: "\n")
        }
        return nil
    }

    /// Adds, changes, or removes the due date on exactly one action line.
    ///
    /// Same discipline as `markdownBySettingActionItem`: the item is matched
    /// by ordinal and exact text so a file edited elsewhere is reported as
    /// stale rather than rewritten from a stale model. The checkbox state and
    /// every other byte of the document stay untouched.
    static func markdownBySettingActionItemDue(
        _ target: ActionItemLine,
        dueTo date: Date?,
        in markdown: String
    ) -> String? {
        let lines = markdown.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard
            let headingIndex = lines.firstIndex(where: {
                isHeadingLine($0, "action items")
            }),
            lines.indices.contains(headingIndex)
        else {
            return nil
        }

        var ordinal = -1
        for position in lines.index(after: headingIndex)..<lines.count {
            let line = lines[position]
            if MarkdownCodec.recognizedHeadings.contains(
                line.trimmingCharacters(in: .whitespaces)
            ) {
                break
            }
            guard let box = checkbox(in: line[...]) else { continue }
            ordinal += 1
            guard ordinal == target.index else { continue }
            guard box.text == target.text else { return nil }

            // The suffix lives at the end of the text; the base wording and
            // the checked state survive any change untouched.
            let baseText = target.displayText
            let newText: String
            if let date {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone.current
                newText = "\(baseText) [due: \(formatter.string(from: date))]"
            } else {
                newText = baseText
            }

            let leading = String(line.prefix(
                while: { $0 == " " || $0 == "\t" }
            ))
            let rewritten =
                leading + "- [\(target.isChecked ? "x" : " ")] \(newText)"
            var result = lines
            result[position] = rewritten
            return result.joined(separator: "\n")
        }
        return nil
    }

    private static func checkbox(
        in line: Substring
    ) -> (isChecked: Bool, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for (marker, checked) in [
            ("- [ ] ", false),
            ("- [x] ", true),
            ("- [X] ", true)
        ] {
            if trimmed.hasPrefix(marker) {
                return (checked, String(trimmed.dropFirst(marker.count)))
            }
        }
        return nil
    }

    /// The text between a "## Title" heading line and the next one.
    ///
    /// Anchored to whole lines deliberately. A substring search used to find
    /// the marker anywhere, so heading-like fragments inside a transcript or
    /// summary shifted where sections ended, and free text a user typed under
    /// "My notes" was cut short by their own "## " line and then lost when the
    /// field was saved back from the truncated model. Only a line whose entire
    /// content is the marker counts as a boundary.
    static func section(_ title: String, in markdown: String) -> String {
        let marker = "## \(title)"
        let lines = markdown.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces)
                .caseInsensitiveCompare(marker) == .orderedSame
        }) else {
            return ""
        }

        var collected: [Substring] = []
        for line in lines[lines.index(after: start)...] {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("## ") {
                break
            }
            collected.append(line)
        }
        return collected.joined(separator: "\n")
    }

    /// Everything under the "My notes" heading, to the next section Nook
    /// itself writes.
    ///
    /// This field is user-authored free text, and people write their own
    /// "## " sub-headings in it. Treating those as boundaries used to cut the
    /// field short on decode, and saving from the truncated model then
    /// deleted everything past the first one permanently. Only headings the
    /// encoder produces act as boundaries here; anything else belongs to the
    /// user's notes and survives the round-trip.
    static func personalNotesContent(in markdown: String) -> String {
        let lines = markdown.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces)
                .lowercased() == "## my notes"
        }) else {
            return ""
        }

        var collected: [Substring] = []
        for line in lines[lines.index(after: start)...] {
            let heading = line.trimmingCharacters(in: .whitespaces)
                .lowercased()
            if MarkdownCodec.recognizedHeadings.contains(heading) {
                break
            }
            collected.append(line)
        }
        let content = collected.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return content == "_No personal notes._" ? "" : content
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

    /// Everything after the first heading, to the end of the file.
    ///
    /// A spoken note keeps its text here: it is one piece of prose, not a set
    /// of meeting sections, and burying it under a "Summary" heading would
    /// misdescribe it in every editor that opens the file.
    ///
    /// Reading to the end is deliberate. Stopping at the first "## " lost
    /// everything past any heading the prose itself contained, which an
    /// assistant action produced every single time it ran.
    private static func bodyText(in markdown: String) -> String {
        guard let headingRange = markdown.range(
            of: "\n# ",
            options: []
        ) else {
            return ""
        }
        let afterHeading = markdown[headingRange.upperBound...]
        guard let lineBreak = afterHeading.firstIndex(of: "\n") else {
            return ""
        }
        let body = String(afterHeading[afterHeading.index(after: lineBreak)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return withoutLegacySpokenSections(body)
    }

    /// Removes the empty sections an earlier spoken-note layout wrote.
    ///
    /// That layout put "## Action items" and "## My notes" after the body,
    /// which is what made a heading in the prose truncate the file. Now that
    /// the body runs to the end, those trailing sections would otherwise
    /// reappear as literal text inside somebody's note.
    ///
    /// Only the exact placeholders the old encoder produced are removed, so a
    /// note that genuinely says "## My notes" keeps it. This can be deleted
    /// once no files in that layout remain; it never reached a release.
    private static func withoutLegacySpokenSections(_ body: String) -> String {
        let placeholders = [
            "\n## Action items\n\n_None captured._",
            "\n## My notes\n\n_No personal notes._"
        ]
        var result = body

        // Repeated rather than one pass: the sections were written in a fixed
        // order, so removing the last one exposes the one before it.
        var removedSomething = true
        while removedSomething {
            removedSomething = false
            for placeholder in placeholders {
                guard let range = result.range(
                    of: placeholder,
                    options: [.backwards]
                ) else {
                    continue
                }
                // Only when nothing but whitespace follows: text mid-note that
                // happens to match is the user's own writing.
                guard result[range.upperBound...].trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty else {
                    continue
                }
                result.removeSubrange(range.lowerBound..<result.endIndex)
                removedSomething = true
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
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
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func unquote(_ value: String) -> String {
        guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else {
            return value
        }
        let content = value.dropFirst().dropLast()
        var result = ""
        var isEscaped = false
        for character in content {
            if isEscaped {
                switch character {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "\\": result.append("\\")
                case "\"": result.append("\"")
                default:
                    result.append("\\")
                    result.append(character)
                }
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else {
                result.append(character)
            }
        }
        if isEscaped { result.append("\\") }
        return result
    }

    private static func headingText(_ value: String) -> String {
        value
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isoString(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func isoDate(from value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}
