import Foundation
import FoundationModels

struct MeetingInsights: Equatable, Sendable {
    var title: String
    var summary: String
    var keyPoints: [String]
    var decisions: [String]
    var actionItems: [String]
}

actor SummaryService {
    func summarize(transcript: [TranscriptSegment], fallbackTitle: String) async -> MeetingInsights {
        let text = transcript.map {
            "[\($0.timestamp)] \($0.source.label): \($0.text)"
        }.joined(separator: "\n")
        guard !text.isEmpty else {
            return MeetingInsights(
                title: fallbackTitle,
                summary: "No speech was detected in this recording.",
                keyPoints: [],
                decisions: [],
                actionItems: []
            )
        }

        if SystemLanguageModel.default.isAvailable {
            do {
                let insights = try await summarizeWithAppleIntelligence(
                    text: text,
                    fallbackTitle: fallbackTitle
                )
                return finalized(
                    insights,
                    transcript: transcript,
                    fallbackTitle: fallbackTitle
                )
            } catch {
                let insights = heuristicSummary(
                    text: text,
                    fallbackTitle: fallbackTitle
                )
                return finalized(
                    insights,
                    transcript: transcript,
                    fallbackTitle: fallbackTitle
                )
            }
        }
        let insights = heuristicSummary(text: text, fallbackTitle: fallbackTitle)
        return finalized(
            insights,
            transcript: transcript,
            fallbackTitle: fallbackTitle
        )
    }

    private func summarizeWithAppleIntelligence(
        text: String,
        fallbackTitle: String
    ) async throws -> MeetingInsights {
        let chunks = text.chunked(maxCharacters: 7_000)
        var condensed: [String] = []

        for (index, chunk) in chunks.enumerated() {
            let session = LanguageModelSession(
                instructions: """
                You create faithful private meeting notes. Never invent owners, dates, decisions, or facts.
                Be concise. Preserve names and concrete commitments.
                """
            )
            let response = try await session.respond(
                to: """
                Condense part \(index + 1) of \(chunks.count) of a meeting transcript.
                Capture key facts, decisions, open questions, and explicit action items.

                TRANSCRIPT:
                \(chunk)
                """
            )
            condensed.append(response.content)
        }

        let session = LanguageModelSession(
            instructions: """
            You turn meeting transcripts into accurate structured notes.
            Output exactly these Markdown headings: # Title, ## Summary, ## Key points,
            ## Decisions, ## Action items. Use bullets under the last three headings.
            For actions, preserve an owner and due date only when stated. Never invent details.
            The title must be a short, specific description of the main subject,
            not a date, app name, generic "Meeting" label, or opening pleasantry.
            """
        )
        let response = try await session.respond(
            to: """
            Create the final meeting note from these faithful transcript extracts.
            Use "\(fallbackTitle)" only when the transcript truly has no
            identifiable subject.

            \(condensed.joined(separator: "\n\n---\n\n"))
            """
        )
        return parseModelResponse(response.content, fallbackTitle: fallbackTitle)
    }

    private func parseModelResponse(_ markdown: String, fallbackTitle: String) -> MeetingInsights {
        let title = markdown.split(separator: "\n")
            .first(where: { $0.hasPrefix("# ") })
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            ?? fallbackTitle
        return MeetingInsights(
            title: title,
            summary: MarkdownCodec.section("Summary", in: markdown)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            keyPoints: NoteContentSanitizer.meaningfulItems(
                bullets(in: MarkdownCodec.section("Key points", in: markdown))
            ),
            decisions: NoteContentSanitizer.meaningfulItems(
                bullets(in: MarkdownCodec.section("Decisions", in: markdown))
            ),
            actionItems: NoteContentSanitizer.meaningfulItems(
                bullets(in: MarkdownCodec.section("Action items", in: markdown))
            )
        )
    }

    private func heuristicSummary(text: String, fallbackTitle: String) -> MeetingInsights {
        let sentences = text
            .replacingOccurrences(of: #"\[\d{2}:\d{2}(?::\d{2})?\]\s*"#, with: "", options: .regularExpression)
            .split(whereSeparator: { ".!?".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 15 }

        let actionWords = ["action", "will ", "need to", "follow up", "todo", "to-do", "by friday", "by monday"]
        let decisionWords = ["decided", "agreed", "decision", "we'll go with", "approved"]
        let actions = sentences.filter { sentence in
            actionWords.contains { sentence.localizedCaseInsensitiveContains($0) }
        }.prefix(6)
        let decisions = sentences.filter { sentence in
            decisionWords.contains { sentence.localizedCaseInsensitiveContains($0) }
        }.prefix(6)

        return MeetingInsights(
            title: MeetingTitleGenerator.heuristicTitle(
                from: sentences,
                fallbackTitle: fallbackTitle
            ),
            summary: sentences.prefix(3).joined(separator: ". ") + (sentences.isEmpty ? "" : "."),
            keyPoints: Array(sentences.prefix(6)),
            decisions: Array(decisions),
            actionItems: Array(actions)
        )
    }

    private func finalized(
        _ insights: MeetingInsights,
        transcript: [TranscriptSegment],
        fallbackTitle: String
    ) -> MeetingInsights {
        var grounded = MeetingInsightGrounder.ground(insights, in: transcript)
        grounded.title = MeetingTitleGenerator.resolvedTitle(
            proposedTitle: grounded.title,
            summary: grounded.summary,
            keyPoints: grounded.keyPoints,
            transcript: transcript,
            fallbackTitle: fallbackTitle
        )
        return grounded
    }
}

enum MeetingTitleGenerator {
    static func resolvedTitle(
        proposedTitle: String,
        summary: String,
        keyPoints: [String],
        transcript: [TranscriptSegment],
        fallbackTitle: String
    ) -> String {
        let proposed = cleanedTitle(proposedTitle)
        if !isFallbackTitle(proposed, fallbackTitle: fallbackTitle) {
            return proposed
        }

        let summarySentences = summary
            .split(whereSeparator: { ".!?".contains($0) })
            .map(String.init)
        let transcriptSentences = transcript
            .map(\.text)
            .filter { $0.count > 15 }
        return heuristicTitle(
            from: keyPoints + summarySentences + transcriptSentences,
            fallbackTitle: fallbackTitle
        )
    }

    static func isFallbackTitle(
        _ title: String,
        fallbackTitle: String
    ) -> Bool {
        let normalized = cleanedTitle(title).lowercased()
        let normalizedFallback = cleanedTitle(fallbackTitle).lowercased()
        guard !normalized.isEmpty else { return true }
        if normalized == normalizedFallback { return true }
        // Timestamp fallbacks in every shape Nook has generated. The dashed
        // forms are still recognised so notes saved by older versions are not
        // suddenly treated as having a real title.
        return genericTitles.contains(normalized)
            || normalized.hasPrefix("meeting —")
            || normalized.hasPrefix("meeting -")
            // The generated form is "Meeting Wed 2:03 PM". Requiring the time
            // as well keeps a title somebody actually typed, such as
            // "Meeting Mon Standup", from being mistaken for a placeholder.
            || normalized.range(
                of: #"^meeting\s+(mon|tue|wed|thu|fri|sat|sun)\s+\d{1,2}:\d{2}"#,
                options: [.regularExpression]
            ) != nil
    }

    static func heuristicTitle(
        from sentences: [String],
        fallbackTitle: String
    ) -> String {
        let conversationalOpeners = [
            "okay",
            "ok",
            "hello",
            "hi ",
            "thanks everyone",
            "thank you",
            "can you hear",
            "let me share",
        ]

        for sentence in sentences {
            var candidate = strippedLeadIn(
                sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            if let colon = candidate.firstIndex(of: ":") {
                let speaker = candidate[..<colon].lowercased()
                if ["you", "meeting", "speaker"].contains(
                    where: { speaker.contains($0) }
                ) {
                    candidate = String(candidate[candidate.index(after: colon)...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            let normalized = candidate.lowercased()
            guard !conversationalOpeners.contains(
                where: { normalized.hasPrefix($0) }
            ) else {
                continue
            }

            let words = candidate.split(whereSeparator: \.isWhitespace)
            guard words.count >= 3 else { continue }
            let title = cleanedTitle(words.prefix(8).joined(separator: " "))
            guard let first = title.first else { continue }
            return String(first).uppercased() + title.dropFirst()
        }
        return fallbackTitle
    }

    private static func strippedLeadIn(_ value: String) -> String {
        let leadIns = [
            "the meeting transcript begins with ",
            "the meeting begins with ",
            "the meeting focused on ",
            "the discussion focused on ",
            "the team discussed ",
            "this meeting covered ",
            "the conversation covered ",
        ]
        let normalized = value.lowercased()
        guard let leadIn = leadIns.first(where: normalized.hasPrefix) else {
            return value
        }
        return String(value.dropFirst(leadIn.count))
    }

    private static func cleanedTitle(_ value: String) -> String {
        var title = value.trimmingCharacters(
            in: CharacterSet.punctuationCharacters
                .union(.whitespacesAndNewlines)
        )
        if title.count > 58 {
            title = String(title.prefix(58))
                .trimmingCharacters(
                    in: CharacterSet.punctuationCharacters
                        .union(.whitespacesAndNewlines)
                )
        }
        return title
    }

    private static let genericTitles: Set<String> = [
        "meeting",
        "manual meeting",
        "zoom meeting",
        "teams meeting",
        "google meet meeting",
        "browser meeting",
        "untitled meeting",
        "title",
    ]
}

private extension SummaryService {
    func bullets(in section: String) -> [String] {
        section.split(separator: "\n").compactMap { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("- ") || value.hasPrefix("* ") else { return nil }
            return String(value.dropFirst(2))
                .replacingOccurrences(of: #"^\[[ xX]\]\s*"#, with: "", options: .regularExpression)
        }
    }
}

enum MeetingInsightGrounder {
    static func ground(
        _ insights: MeetingInsights,
        in transcript: [TranscriptSegment]
    ) -> MeetingInsights {
        var grounded = insights
        let spokenLines = transcript.map {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let actionLines = spokenLines.filter {
            containsPositiveSignal($0, signals: actionSignals)
        }
        let decisionLines = spokenLines.filter {
            containsPositiveSignal($0, signals: decisionSignals)
        }

        if actionLines.isEmpty {
            grounded.actionItems = []
        }
        if decisionLines.isEmpty {
            grounded.decisions = []
        }
        return grounded
    }

    private static func containsPositiveSignal(
        _ text: String,
        signals: [String]
    ) -> Bool {
        let negativeSignals = [
            "no action",
            "no decision",
            "nothing to follow up",
            "not decided",
            "none",
        ]
        guard !negativeSignals.contains(where: text.contains) else { return false }
        return signals.contains(where: text.contains)
    }

    private static let actionSignals = [
        "i will ",
        "i’ll ",
        "i'll ",
        "we will ",
        "we’ll ",
        "we'll ",
        "can you ",
        "could you ",
        "please ",
        "need to ",
        "needs to ",
        "follow up",
        "action item",
        "to-do",
        "todo",
        " by friday",
        " by monday",
        " by tuesday",
        " by wednesday",
        " by thursday",
    ]

    private static let decisionSignals = [
        "we decided",
        "decided to",
        "we agreed",
        "agreed to",
        "approved ",
        "we’ll go with",
        "we'll go with",
        "decision is",
        "let’s go with",
        "let's go with",
    ]
}

private extension String {
    func chunked(maxCharacters: Int) -> [String] {
        guard count > maxCharacters else { return [self] }
        var chunks: [String] = []
        var current = ""
        for line in split(separator: "\n", omittingEmptySubsequences: false) {
            let value = String(line) + "\n"
            if current.count + value.count > maxCharacters, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += value
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
