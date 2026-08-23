import Foundation

enum MarkdownCodec {
    static func encode(_ note: MeetingNote) -> String {
        let keyPoints = bulletList(note.keyPoints)
        let decisions = bulletList(note.decisions)
        // Completion is carried beside the item text rather than derived, so a
        // rename or a personal-notes save re-encodes ticked items as ticked
        // instead of reopening every one of them.
        let actions = checklist(
            note.actionItems,
            completed: note.completedActionItems
        )
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

        // Blocks separated by a blank line, which is exactly the layout the
        // file has always had. Building it as a list rather than one literal
        // is what lets preserved sections go back where their author left
        // them instead of being appended somewhere at the end.
        var blocks: [String] = ["# \(headingText(note.title))"]
        var placedAnchors: Set<String> = []

        func appendPreserved(anchoredTo anchor: String?) {
            if let anchor { placedAnchors.insert(anchor) }
            for extra in note.extraSections where extra.anchor == anchor {
                if let heading = extra.heading {
                    blocks.append(heading)
                }
                let body = extra.body.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                if !body.isEmpty {
                    blocks.append(body)
                }
            }
        }

        func appendSection(_ heading: String, _ content: String) {
            blocks.append("## \(heading)")
            blocks.append(content)
            appendPreserved(anchoredTo: "## \(heading.lowercased())")
        }

        // Anything written above the first section keeps its place too.
        appendPreserved(anchoredTo: nil)
        appendSection(
            "Summary",
            note.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        appendSection("Key points", keyPoints)
        appendSection("Decisions", decisions)
        appendSection("Action items", actions)

        // A digest is compiled, not recorded: it carries the period's
        // overview and outcomes but no transcript and no personal notes.
        if note.kind != .digest {
            appendSection(
                "My notes",
                personalNotes.isEmpty ? "_No personal notes._" : personalNotes
            )
            appendSection(
                "Transcript",
                transcript.isEmpty ? "_No speech was detected._" : transcript
            )
        }

        // A block anchored to a heading this note does not write still has to
        // land somewhere. Dropping it would be exactly the loss the anchor
        // exists to prevent, so it goes at the end instead.
        for anchor in note.extraSections.compactMap(\.anchor)
        where !placedAnchors.contains(anchor) {
            appendPreserved(anchoredTo: anchor)
        }

        return ([frontmatter] + blocks).joined(separator: "\n\n")
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
        let blocks = kind == .spoken ? [] : bodyBlocks(in: markdown)
        // A spoken note carries its text under the heading rather than under a
        // "## Summary" marker, so it is read back from the body.
        let summary = kind == .spoken
            ? bodyText(in: markdown)
            : proseSection("Summary", in: blocks)

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
            listItems(in: body(of: "Key points", in: blocks))
        )
        let decisions = NoteContentSanitizer.meaningfulItems(
            listItems(in: body(of: "Decisions", in: blocks))
        )
        let actionChecklist = checklistItems(
            in: body(of: "Action items", in: blocks)
        )
        let actionItems = NoteContentSanitizer.meaningfulItems(
            actionChecklist.map(\.text)
        )
        // Only genuine items carry a completion bit, so a placeholder bullet
        // can never come back as a ticked task.
        let completedActionItems = Set(
            actionChecklist.filter(\.isChecked).map(\.text)
        ).intersection(actionItems)
        let personalNotes = personalNotesContent(in: blocks)
        let transcript = TranscriptAssembler.coalesce(
            transcriptItems(in: body(of: "Transcript", in: blocks))
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
            completedActionItems: completedActionItems,
            personalNotes: personalNotes,
            transcript: transcript,
            moments: moments,
            sessions: sessions,
            audioStart: audioStart,
            extraSections: preservedSections(in: blocks),
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
        let result = text.replacingOccurrences(
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
        rewriteCheckbox(
            target,
            checked: checked,
            in: markdown,
            scopedToActionItemsSection: true
        )
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
        return rewriteDue(
            scopedToActionItemsSection: true,
            target: target,
            dueTo: date,
            in: markdown
        )
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

    // MARK: Spoken-note checkboxes

    /// Checkbox lines anywhere below a spoken note's title, in file order.
    ///
    /// A spoken note's file is title then prose by contract: trailing
    /// sections were removed because a dictated heading would swallow
    /// anything after it. Structure therefore lives inline, and the task
    /// pipeline reads it where it actually is rather than asking the format
    /// to change.
    static func spokenCheckboxLines(in markdown: String) -> [ActionItemLine] {
        collectCheckboxLines(in: markdown, scopedToActionItemsSection: false)
    }

    /// Rewrites one spoken-note checkbox in place, matching by ordinal and
    /// exact text like the section-scoped rewriters.
    static func markdownBySettingSpokenCheckbox(
        _ target: ActionItemLine,
        checked: Bool,
        in markdown: String
    ) -> String? {
        rewriteCheckbox(
            target,
            checked: checked,
            in: markdown,
            scopedToActionItemsSection: false
        )
    }

    /// Adds, changes, or removes a due suffix on one spoken-note checkbox.
    static func markdownBySettingSpokenCheckboxDue(
        _ target: ActionItemLine,
        dueTo date: Date?,
        in markdown: String
    ) -> String? {
        rewriteDue(
            scopedToActionItemsSection: false,
            target: target,
            dueTo: date,
            in: markdown
        )
    }

    // MARK: - Shared line rewriting

    private static func collectCheckboxLines(
        in markdown: String,
        scopedToActionItemsSection: Bool
    ) -> [ActionItemLine] {
        let lines = markdown.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        var items: [ActionItemLine] = []
        if scopedToActionItemsSection {
            guard
                let headingIndex = lines.firstIndex(where: {
                    isHeadingLine($0, "action items")
                })
            else { return [] }
            for line in lines[lines.index(after: headingIndex)...] {
                if MarkdownCodec.recognizedHeadings.contains(
                    line.trimmingCharacters(in: .whitespaces).lowercased()
                ) { break }
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

        // Whole-body scope: skip everything through the title heading so
        // frontmatter can never masquerade as tasks.
        let bodyStart = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("# ")
        }).map { lines.index(after: $0) } ?? lines.startIndex
        for line in lines[bodyStart...] {
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

    private static func rewriteCheckbox(
        _ target: ActionItemLine,
        checked: Bool,
        in markdown: String,
        scopedToActionItemsSection: Bool
    ) -> String? {
        let lines = markdown.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)

        var ordinal = -1
        for position in editableRange(
            of: lines,
            scopedToActionItemsSection: scopedToActionItemsSection
        ) {
            let line = lines[position]
            if scopedToActionItemsSection,
               MarkdownCodec.recognizedHeadings.contains(
                   line.trimmingCharacters(in: .whitespaces).lowercased()
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

    private static func rewriteDue(
        scopedToActionItemsSection: Bool,
        target: ActionItemLine,
        dueTo date: Date?,
        in markdown: String
    ) -> String? {
        let lines = markdown.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)

        var ordinal = -1
        for position in editableRange(
            of: lines,
            scopedToActionItemsSection: scopedToActionItemsSection
        ) {
            let line = lines[position]
            if scopedToActionItemsSection,
               MarkdownCodec.recognizedHeadings.contains(
                   line.trimmingCharacters(in: .whitespaces).lowercased()
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

    /// The line positions a rewriter may consider: below the Action items
    /// heading until the next recognised section when scoped, or everywhere
    /// below the title for whole-body scope.
    private static func editableRange(
        of lines: [String],
        scopedToActionItemsSection: Bool
    ) -> Range<Int> {
        if scopedToActionItemsSection {
            guard
                let headingIndex = lines.firstIndex(where: {
                    $0.trimmingCharacters(in: .whitespaces)
                        .lowercased() == "## action items"
                }),
                lines.indices.contains(headingIndex)
            else { return 0..<0 }
            return lines.index(after: headingIndex)..<lines.count
        }
        let bodyStart = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("# ")
        }).map { lines.index(after: $0) } ?? lines.startIndex
        return bodyStart..<lines.count
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
        body(of: title, in: bodyBlocks(in: markdown))
    }

    /// One top-level piece of a note's body: a "## " heading and the lines
    /// beneath it, or the lines above the first heading.
    struct BodyBlock: Hashable, Sendable {
        /// The heading line exactly as written, or nil for the leading block.
        let heading: String?
        /// That heading lowercased, for `recognizedHeadings` lookups.
        let normalizedHeading: String?
        /// The lines under the heading, verbatim.
        let body: String
    }

    /// Splits a note's body into its top-level blocks.
    ///
    /// Frontmatter and the title are skipped by position rather than by
    /// searching for a heading, so a file whose "# " line somebody deleted is
    /// still read as a body instead of decoding to nothing.
    static func bodyBlocks(in markdown: String) -> [BodyBlock] {
        let lines = markdown.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        var blocks: [BodyBlock] = []
        var heading: String?
        var buffer: [Substring] = []

        func flush() {
            let body = buffer.joined(separator: "\n")
            let isEmptyLead = heading == nil
                && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !isEmptyLead {
                blocks.append(
                    BodyBlock(
                        heading: heading,
                        normalizedHeading: heading?.lowercased(),
                        body: body
                    )
                )
            }
            buffer = []
        }

        for line in lines[bodyLineStart(of: lines)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                flush()
                heading = trimmed
                continue
            }
            buffer.append(line)
        }
        flush()
        return blocks
    }

    /// Where a note's body starts: past the frontmatter, then past the title.
    private static func bodyLineStart(of lines: [Substring]) -> Int {
        var start = lines.startIndex
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let close = lines.dropFirst().firstIndex(where: {
               $0.trimmingCharacters(in: .whitespaces) == "---"
           }) {
            start = lines.index(after: close)
        }
        if let title = lines[start...].firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }), lines[title].trimmingCharacters(in: .whitespaces).hasPrefix("# ") {
            start = lines.index(after: title)
        }
        return start
    }

    /// The verbatim body of one named section, or "" when the file has none.
    static func body(of title: String, in blocks: [BodyBlock]) -> String {
        let marker = "## \(title.lowercased())"
        return blocks.first { $0.normalizedHeading == marker }?.body ?? ""
    }

    /// A prose section's text, including any "## " sub-headings written inside
    /// it, to the next section Nook itself writes.
    ///
    /// Summary and My notes are user-authored free text, and people write
    /// their own sub-headings in them. Treating those as boundaries cut the
    /// field short on decode, and saving from the truncated model then deleted
    /// everything past the first one permanently. Only headings the encoder
    /// produces act as boundaries here.
    static func proseSection(_ title: String, in blocks: [BodyBlock]) -> String {
        let marker = "## \(title.lowercased())"
        guard let start = blocks.firstIndex(where: {
            $0.normalizedHeading == marker
        }) else {
            return ""
        }

        var pieces = [blocks[start].body]
        for block in blocks[blocks.index(after: start)...] {
            guard let normalized = block.normalizedHeading,
                  !recognizedHeadings.contains(normalized)
            else { break }
            pieces.append(block.heading ?? "")
            pieces.append(block.body)
        }
        return pieces.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func personalNotesContent(in blocks: [BodyBlock]) -> String {
        let content = proseSection("My notes", in: blocks)
        return content == "_No personal notes._" ? "" : content
    }

    /// The sections Nook models as lists, whose non-list lines would otherwise
    /// be dropped by the list parser.
    private static let listSectionHeadings: Set<String> = [
        "## key points",
        "## decisions",
        "## action items"
    ]

    /// Everything in the body that no field models, in file order.
    ///
    /// Without this, a hand-written "## Agenda" and any prose sitting inside a
    /// list section vanished the next time anything saved the whole note,
    /// because encoding rebuilds the document from the fields alone.
    static func preservedSections(in blocks: [BodyBlock]) -> [ExtraSection] {
        var extras: [ExtraSection] = []
        var anchor: String?
        // Summary and My notes keep their own sub-headings as part of their
        // text, so those blocks are already accounted for.
        var anchorKeepsItsSubheadings = false

        for block in blocks {
            guard let normalized = block.normalizedHeading else {
                let body = block.body.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                if !body.isEmpty {
                    extras.append(
                        ExtraSection(heading: nil, body: body, anchor: nil)
                    )
                }
                continue
            }
            if recognizedHeadings.contains(normalized) {
                anchor = normalized
                anchorKeepsItsSubheadings = normalized == "## summary"
                    || normalized == "## my notes"
                if let loose = looseLines(in: block, under: normalized) {
                    extras.append(
                        ExtraSection(
                            heading: nil,
                            body: loose,
                            anchor: normalized
                        )
                    )
                }
                continue
            }
            guard !anchorKeepsItsSubheadings else { continue }
            extras.append(
                ExtraSection(
                    heading: block.heading,
                    body: block.body,
                    anchor: anchor
                )
            )
        }
        return extras
    }

    /// Lines inside a list section that the list parser would throw away.
    ///
    /// They are re-emitted below that section's items rather than at their
    /// original offset, so a paragraph written above a list moves below it
    /// once. Keeping the words in the wrong order beats deleting them.
    private static func looseLines(
        in block: BodyBlock,
        under heading: String
    ) -> String? {
        guard listSectionHeadings.contains(heading) else { return nil }
        let kept = block.body.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty
                && !trimmed.hasPrefix("- ")
                && trimmed != "_None captured._"
        }
        guard !kept.isEmpty else { return nil }
        return kept.joined(separator: "\n")
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
    ///
    /// The heading is found by position, not by searching for "\n# ". People
    /// delete that line by hand, and a search-based read then returned nothing
    /// for a file full of words, which the next save wrote back as an empty
    /// note. Everything after the frontmatter is the body when there is no
    /// title line to skip.
    private static func bodyText(in markdown: String) -> String {
        let lines = markdown.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        let body = lines[bodyLineStart(of: lines)...]
            .joined(separator: "\n")
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
        checklistItems(in: section).map(\.text)
    }

    /// List items with their checkbox state, in file order.
    ///
    /// The state is read here and carried on the model, because encoding
    /// rebuilds every list from the model alone: a decode that dropped the box
    /// meant the next whole-note save reopened every finished task.
    private static func checklistItems(
        in section: String
    ) -> [(text: String, isChecked: Bool)] {
        section.split(separator: "\n").compactMap { rawLine in
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- ") else { return nil }
            line.removeFirst(2)
            var isChecked = false
            if line.hasPrefix("[ ] ") {
                line.removeFirst(4)
            } else if line.hasPrefix("[x] ") || line.hasPrefix("[X] ") {
                line.removeFirst(4)
                isChecked = true
            }
            return (line, isChecked)
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

    private static func bulletList(_ values: [String]) -> String {
        guard !values.isEmpty else { return "_None captured._" }
        return values.map { "- " + $0 }.joined(separator: "\n")
    }

    private static func checklist(
        _ values: [String],
        completed: Set<String>
    ) -> String {
        guard !values.isEmpty else { return "_None captured._" }
        return values
            .map { "- [\(completed.contains($0) ? "x" : " ")] \($0)" }
            .joined(separator: "\n")
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
