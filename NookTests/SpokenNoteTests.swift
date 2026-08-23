import Foundation
import Testing
@testable import Nook

struct SpokenNoteTests {
    private func spokenNote(
        body: String = "Ship the release on Friday and tell the team.",
        title: String = "Ship the release on Friday"
    ) -> MeetingNote {
        MeetingNote(
            kind: .spoken,
            title: title,
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            endedAt: Date(timeIntervalSince1970: 1_000_060),
            sourceApp: "Spoken note",
            summary: body
        )
    }

    @Test
    func aSpokenNoteSurvivesTheRoundTrip() throws {
        let note = spokenNote()

        let decoded = try #require(MarkdownCodec.decode(MarkdownCodec.encode(note)))

        #expect(decoded.kind == .spoken)
        #expect(decoded.id == note.id)
        #expect(decoded.title == note.title)
        #expect(decoded.summary == note.summary)
    }

    /// A spoken note is one piece of prose. Filing it under meeting headings
    /// would describe it wrongly in every editor that opens the file.
    @Test
    func aSpokenNoteOmitsTheMeetingSections() {
        let markdown = MarkdownCodec.encode(spokenNote())

        #expect(markdown.contains("kind: spoken"))
        #expect(!markdown.contains("## Summary"))
        #expect(!markdown.contains("## Key points"))
        #expect(!markdown.contains("## Decisions"))
        #expect(!markdown.contains("## Transcript"))
        #expect(!markdown.contains("## Action items"))
        #expect(markdown.contains("Ship the release on Friday and tell the team."))
    }

    @Test
    func aMeetingKeepsEveryMeetingSection() {
        let meeting = MeetingNote(
            title: "Weekly review",
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            endedAt: Date(timeIntervalSince1970: 1_003_600),
            sourceApp: "Teams",
            summary: "The team reviewed the release."
        )

        let markdown = MarkdownCodec.encode(meeting)

        #expect(markdown.contains("kind: meeting"))
        #expect(markdown.contains("## Summary"))
        #expect(markdown.contains("## Transcript"))
    }

    /// Every note written before spoken notes existed lacks the marker, and
    /// silently reclassifying a meeting would lose its transcript on the next
    /// save.
    @Test
    func notesWithoutTheMarkerRemainMeetings() throws {
        let markdown = """
        ---
        id: 3B9C2A5E-1F4D-4E7A-9C11-8D2F6A0B4E33
        title: "Older meeting"
        started: 2026-07-30T02:00:00Z
        ended: 2026-07-30T03:00:00Z
        source: "Zoom"
        ---

        # Older meeting

        ## Summary

        A meeting recorded before spoken notes existed.

        ## Transcript

        - **[00:01]** **Meeting:** Hello everyone.
        """

        let decoded = try #require(MarkdownCodec.decode(markdown))

        #expect(decoded.kind == .meeting)
        #expect(decoded.summary == "A meeting recorded before spoken notes existed.")
        #expect(decoded.transcript.count == 1)
    }

    /// Existing notes are re-encoded whenever a user edits personal notes, so
    /// the new frontmatter key must add itself without disturbing anything
    /// already on disk.
    @Test
    func anExistingMeetingNoteReEncodesWithoutLoss() throws {
        let original = """
        ---
        id: 3B9C2A5E-1F4D-4E7A-9C11-8D2F6A0B4E33
        title: "Pricing review"
        started: 2026-07-30T02:00:00Z
        ended: 2026-07-30T03:00:00Z
        source: "Zoom"
        ---

        # Pricing review

        ## Summary

        The team agreed to hold pricing until the migration lands.

        ## Key points

        - [ ] Migration is the blocker
        - [ ] Two customers asked about tiers

        ## Decisions

        - [ ] Hold pricing changes until Q4

        ## Action items

        - [ ] Luke to draft the tier comparison

        ## My notes

        Ask about the enterprise discount next time.

        ## Transcript

        - **[00:01]** **Meeting:** Shall we start with pricing?
        - **[00:07]** **You:** Yes, but the migration comes first.
        """

        let first = try #require(MarkdownCodec.decode(original))
        let reEncoded = MarkdownCodec.encode(first)
        let second = try #require(MarkdownCodec.decode(reEncoded))

        #expect(second.kind == .meeting)
        #expect(second.id == first.id)
        #expect(second.title == first.title)
        #expect(second.summary == first.summary)
        #expect(second.keyPoints == first.keyPoints)
        #expect(second.decisions == first.decisions)
        #expect(second.actionItems == first.actionItems)
        #expect(second.personalNotes == first.personalNotes)
        #expect(second.transcript.map(\.text) == first.transcript.map(\.text))
        #expect(second.startedAt == first.startedAt)
        #expect(second.endedAt == first.endedAt)
        #expect(second.sourceApp == first.sourceApp)

        // Encoding twice must not keep changing the file.
        #expect(MarkdownCodec.encode(second) == reEncoded)
    }

    /// A spoken note holds everything in its prose, including anything an
    /// assistant action added. Nothing is parsed back out into separate
    /// fields, because writing those out again would duplicate the text the
    /// user is already looking at.
    @Test
    func aSpokenNoteKeepsEverythingInItsBody() throws {
        let body = """
        Remember the docs use ## for sections.

        Second paragraph after that.
        """
        var note = spokenNote(body: body)
        note.actionItems = ["This is not stored separately"]

        let decoded = try #require(MarkdownCodec.decode(MarkdownCodec.encode(note)))

        #expect(decoded.summary == body)
        #expect(decoded.actionItems.isEmpty)
        #expect(decoded.transcript.isEmpty)
        #expect(decoded.personalNotes.isEmpty)
    }

    /// Spoken notes written by the earlier layout have trailing placeholder
    /// sections. Now that the body runs to the end of the file, they would
    /// otherwise show up as literal text inside the user's note.
    @Test
    func legacySpokenNotesDropTheirEmptyTrailingSections() throws {
        let markdown = """
        ---
        id: 7C1E4A88-2B3D-4F5A-9E60-1A2B3C4D5E6F
        kind: spoken
        title: "Toolbar feedback"
        started: 2026-08-12T02:00:00Z
        ended: 2026-08-12T02:00:30Z
        source: "Spoken note"
        ---

        # Toolbar feedback

        The ad hoc note works well, but the toolbar looks sad.

        ## Action items

        _None captured._

        ## My notes

        _No personal notes._
        """

        let decoded = try #require(MarkdownCodec.decode(markdown))

        #expect(
            decoded.summary
                == "The ad hoc note works well, but the toolbar looks sad."
        )
    }

    /// The cleanup must not touch prose that merely resembles it.
    @Test
    func aNoteThatMentionsThoseHeadingsKeepsThem() throws {
        let body = """
        ## My notes

        This is what I actually wrote, and it stays.

        ## Action items

        - Something real
        """

        let decoded = try #require(
            MarkdownCodec.decode(MarkdownCodec.encode(spokenNote(body: body)))
        )

        #expect(decoded.summary == body)
    }

    /// The exact shape every non-replacing note action produces. Ending the
    /// body at the first "## " deleted the result the user had just asked for,
    /// permanently, the next time the note was opened.
    @Test
    func aHeadingInsideTheBodySurvivesIntact() throws {
        let body = """
        The ad hoc note works well, but the toolbar looks sad.

        ## Summarise

        The note captures a UI concern about the toolbar.

        ## Find actions

        - Polish the action bar
        """

        let decoded = try #require(
            MarkdownCodec.decode(MarkdownCodec.encode(spokenNote(body: body)))
        )

        #expect(decoded.summary == body)
        #expect(decoded.summary.contains("Polish the action bar"))
    }

    /// Running an action, saving, reopening, and running another must not lose
    /// anything at any step.
    @Test
    func repeatedActionsAndReloadsNeverLoseContent() throws {
        var body = "Something worth remembering about the release."
        var note = spokenNote(body: body)

        for title in ["Summarise", "Find actions"] {
            let reloaded = try #require(
                MarkdownCodec.decode(MarkdownCodec.encode(note))
            )
            body = reloaded.summary + "\n\n## \(title)\n\nGenerated result."
            note = spokenNote(body: body)
        }

        let final = try #require(MarkdownCodec.decode(MarkdownCodec.encode(note)))

        #expect(final.summary == body)
        #expect(final.summary.contains("Something worth remembering"))
        #expect(final.summary.contains("## Summarise"))
        #expect(final.summary.contains("## Find actions"))
    }

    @Test
    func multiParagraphNotesSurviveIntact() throws {
        let body = """
        The first thought about the release.

        A second, separate thought that came later.
        """
        let decoded = try #require(
            MarkdownCodec.decode(MarkdownCodec.encode(spokenNote(body: body)))
        )

        #expect(decoded.summary == body)
    }
}

struct NoteTitleGeneratorTests {
    @Test
    func namesANoteFromItsOwnWords() {
        let title = NoteTitleGenerator.title(
            for: "We should move the release to Friday so the team has time."
        )

        #expect(title != "Spoken note")
        #expect(title.contains("release") || title.contains("We should"))
    }

    /// Too short for the meeting heuristics to find a subject, but still worth
    /// naming with something the user will recognise in a list.
    @Test
    func fallsBackToTheOpeningWordsForShortNotes() {
        #expect(NoteTitleGenerator.title(for: "Call the bank") == "Call the bank")
    }

    @Test
    func handlesAnEmptyNote() {
        #expect(NoteTitleGenerator.title(for: "") == "Spoken note")
    }

    @Test
    func capitalizesTheOpeningWord() {
        #expect(NoteTitleGenerator.title(for: "remember to renew").hasPrefix("R"))
    }
}

/// What the command-line bridge is allowed to hand a tool.
///
/// Both tools are agents by default, running under the permissions their user
/// already granted for their own work. A note is dictated speech and other
/// people's writing, and it routinely reads as instructions.
struct CommandLineAssistantArgumentTests {
    /// Trimmed to the flags under test. The real help is hundreds of lines and
    /// none of the rest changes the answer.
    private static let claudeHelp = """
        Usage: claude [options] [command] [prompt]
          -p, --print                Print response and exit
          --permission-mode <mode>   Permission mode to use for the session
          --safe-mode                Start with all customizations disabled
          --strict-mcp-config        Only use MCP servers from --mcp-config
          --tools <tools...>         Specify the list of available tools
          --no-session-persistence   Disable session persistence
        """

    private static let codexHelp = """
        Usage: codex exec [OPTIONS] [PROMPT]
          -s, --sandbox <SANDBOX_MODE>  Select the sandbox policy
          --skip-git-repo-check         Allow running outside a Git repository
          --ephemeral                   Run without persisting session files
          --ignore-user-config          Do not load config.toml
          --ignore-rules                Do not load execpolicy rules
        """

    @Test
    func aClaudeRunHasNoToolsNoMCPServersAndNoUserConfiguration() {
        let arguments = CommandLineAssistant.arguments(
            for: .claude,
            instruction: "Tidy this note.",
            supportedFlagsIn: Self.claudeHelp
        )

        #expect(arguments.contains("--safe-mode"))
        #expect(arguments.contains("--strict-mcp-config"))
        #expect(follows("", "--tools", in: arguments))
        #expect(follows("manual", "--permission-mode", in: arguments))
    }

    /// The note is not left behind in a transcript on disk.
    @Test
    func aClaudeRunLeavesNoSessionFileHoldingTheNote() {
        let arguments = CommandLineAssistant.arguments(
            for: .claude,
            instruction: "Tidy this note.",
            supportedFlagsIn: Self.claudeHelp
        )

        #expect(arguments.contains("--no-session-persistence"))
    }

    /// The tool list is variadic, so an instruction placed straight after it
    /// would be read as another tool name and never reach the model.
    @Test
    func theInstructionIsTheLastArgumentAndIsIntroducedByPrintMode() {
        let arguments = CommandLineAssistant.arguments(
            for: .claude,
            instruction: "Tidy this note.",
            supportedFlagsIn: Self.claudeHelp
        )

        #expect(arguments.last == "Tidy this note.")
        #expect(arguments.dropLast().last == "-p")
    }

    /// An unrecognised flag is a hard exit on both tools, and Nook does not
    /// control which version somebody has installed.
    @Test
    func flagsTheInstalledToolDoesNotAdvertiseAreLeftOff() {
        let arguments = CommandLineAssistant.arguments(
            for: .claude,
            instruction: "Tidy this note.",
            supportedFlagsIn: "Usage: claude [options]\n  -p, --print\n"
        )

        #expect(arguments == ["-p", "Tidy this note."])
    }

    /// Nothing is known about the tool, so nothing is assumed about it: a run
    /// that fails loudly beats one that quietly runs unrestricted.
    @Test
    func anUnreadableHelpTextKeepsEveryRestriction() {
        let arguments = CommandLineAssistant.arguments(
            for: .claude,
            instruction: "Tidy this note.",
            supportedFlagsIn: nil
        )

        #expect(arguments.contains("--safe-mode"))
        #expect(arguments.contains("--strict-mcp-config"))
        #expect(follows("", "--tools", in: arguments))
    }

    /// Codex cannot switch its tools off, so the sandbox is the limit, and
    /// ignoring the user's config is what keeps their MCP servers out of it.
    @Test
    func aCodexRunIsReadOnlyAndIgnoresTheUsersOwnConfiguration() {
        let arguments = CommandLineAssistant.arguments(
            for: .codex,
            instruction: "Tidy this note.",
            supportedFlagsIn: Self.codexHelp
        )

        #expect(arguments.first == "exec")
        #expect(follows("read-only", "--sandbox", in: arguments))
        #expect(arguments.contains("--ignore-user-config"))
        #expect(arguments.contains("--ignore-rules"))
        #expect(arguments.contains("--ephemeral"))
        #expect(arguments.last == "Tidy this note.")
    }

    private func follows(
        _ value: String,
        _ flag: String,
        in arguments: [String]
    ) -> Bool {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1)
        else {
            return false
        }
        return arguments[index + 1] == value
    }
}

struct NoteAssistantEngineTests {
    /// The privacy distinction is what the note window labels itself with, so
    /// it has to be right.
    @Test
    func onlyTheOnDeviceEngineStaysOnTheMac() {
        #expect(!NoteAssistantEngine.onDevice.leavesTheMac)
        #expect(NoteAssistantEngine.claude.leavesTheMac)
        #expect(NoteAssistantEngine.codex.leavesTheMac)
    }

    @Test
    func onlyRewritingActionsReplaceTheNote() {
        #expect(NoteAction.tidy.replacesNote)
        #expect(NoteAction.expand.replacesNote)
        #expect(!NoteAction.summarize.replacesNote)
        #expect(!NoteAction.actionItems.replacesNote)
    }

    /// Notes routinely read as instructions. The contract that stops one being
    /// obeyed rather than worked on has to be present in every action.
    @Test
    func everyActionForbidsInventingContent() {
        for action in NoteAction.allCases {
            let instruction = action.instruction.lowercased()
            #expect(
                instruction.contains("not")
                    || instruction.contains("never")
                    || instruction.contains("only")
            )
        }
    }
}

/// Tidy up and Expand replace the note itself, so their output goes through
/// the same drift guard dictation uses. A model handed a note that reads like
/// a request will sometimes answer it instead of rewriting it, and the answer
/// must never overwrite the words the user actually spoke.
struct NoteRewriteTrustTests {
    private let spoken =
        "remember to ship the release on friday and tell the team "
            + "about the pricing change"

    /// An answer shares none of the note's meaning-bearing vocabulary, even
    /// when its length happens to look plausible for a rewrite.
    @Test
    func anAnswerInsteadOfARewriteIsRejected() {
        let answer = """
            Here is a summary of Q3 revenue across regions with detailed \
            breakdowns and forecasts for next quarter including headcount plans.
            """

        for action in [NoteAction.tidy, .expand] {
            let decision = DictationOutputGuard.evaluate(
                refined: answer,
                spoken: spoken,
                maximumLengthRatio: action.maximumRewriteGrowth
            )
            #expect(decision == .reject(.driftedFromSpeech), "\(action)")
        }
    }

    /// Expanding legitimately develops a rough note into structured prose,
    /// which grows well past the tidying ceiling without being drift.
    @Test
    func expandingMayGrowFarMoreThanTidyingAllows() {
        let expanded = """
            Plan for the release: ship it on Friday. Remember that the team \
            needs to hear about the pricing change before then, so prepare a \
            short message covering what changed and why it matters.
            """

        #expect(
            DictationOutputGuard.evaluate(
                refined: expanded,
                spoken: spoken,
                maximumLengthRatio: NoteAction.expand.maximumRewriteGrowth
            ).text != nil
        )
        #expect(
            DictationOutputGuard.evaluate(
                refined: expanded,
                spoken: spoken,
                maximumLengthRatio: NoteAction.tidy.maximumRewriteGrowth
            ) == .reject(.tooLong)
        )
    }

    /// The ordinary case keeps working: a tidy that cleans up the same words.
    @Test
    func aFaithfulTidyIsAccepted() {
        let tidy = "Ship the release Friday and tell the team about the pricing change."

        #expect(
            DictationOutputGuard.evaluate(
                refined: tidy,
                spoken: spoken,
                maximumLengthRatio: NoteAction.tidy.maximumRewriteGrowth
            ).text != nil
        )
    }
}
