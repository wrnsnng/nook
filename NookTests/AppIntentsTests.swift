import Foundation
import Testing
@testable import Nook

/// Shortcuts and Siri reach Nook without its interface, so what the user
/// hears back is the whole experience. These pin where each action sends its
/// words and what it says when the action does not apply, using synthetic
/// notes and no running meeting.
@MainActor
struct AppIntentsTests {
    private func note(
        _ title: String,
        kind: NoteKind = .meeting,
        id: UUID = UUID(),
        daysAgo: Double,
        summary: String = "Talked it through."
    ) -> MeetingNote {
        let start = Date(timeIntervalSince1970: 1_800_000_000 - daysAgo * 86_400)
        return MeetingNote(
            id: id,
            kind: kind,
            title: title,
            startedAt: start,
            endedAt: start.addingTimeInterval(1_800),
            sourceApp: "Zoom",
            summary: summary,
            fileURL: URL(fileURLWithPath: "/synthetic/\(id.uuidString).md")
        )
    }

    // MARK: - Take a Note

    @Test
    func aNoteTakenWhileRecordingJoinsMyNotesAsItsOwnLine() {
        let route = TakeNoteRoute.route(
            text: "  Ask Ana about the budget ",
            isRecording: true,
            liveNotes: "Budget first"
        )
        #expect(route == .addToMyNotes("Budget first\n- Ask Ana about the budget"))
    }

    @Test
    func aNoteWithNoWordsWhileRecordingOpensTheNotchNoteLine() {
        #expect(TakeNoteRoute.route(text: nil, isRecording: true, liveNotes: "") == .askForNoteLine)
        #expect(TakeNoteRoute.route(text: "   ", isRecording: true, liveNotes: "- Kept") == .askForNoteLine)
    }

    @Test
    func aNoteTakenWithNothingRecordingStartsAQuickNote() {
        #expect(
            TakeNoteRoute.route(text: " Buy the domain ", isRecording: false, liveNotes: "Stale")
                == .openQuickNote("Buy the domain")
        )
        #expect(TakeNoteRoute.route(text: nil, isRecording: false, liveNotes: "") == .openQuickNote(nil))
        #expect(TakeNoteRoute.route(text: "\n", isRecording: false, liveNotes: "") == .openQuickNote(nil))
    }

    @Test
    func aSecondQuickNoteLineNeverRunsIntoTheFirst() {
        #expect(TakeNoteRoute.quickNoteText(adding: "Buy milk", to: "") == "Buy milk")
        #expect(TakeNoteRoute.quickNoteText(adding: "Buy milk", to: "Call Sam") == "Call Sam\nBuy milk")
        #expect(TakeNoteRoute.quickNoteText(adding: "Buy milk", to: "Call Sam\n") == "Call Sam\nBuy milk")
    }

    // MARK: - Recording actions

    @Test
    func startingWhileAlreadyRecordingSaysSo() {
        let recording = MeetingPhase.recording(title: "Sync", startedAt: Date())
        #expect(throws: NookIntentError.alreadyRecording) {
            try RecordingIntentRules.checkCanStart(recording)
        }
        #expect(NookIntentError.alreadyRecording.message == "Nook is already recording.")
        #expect(throws: NookIntentError.busyWithRecording) {
            try RecordingIntentRules.checkCanStart(.processing(.summarizing))
        }
    }

    @Test
    func startingIsAllowedWheneverNothingIsRecordingOrProcessing() throws {
        let detected = DetectedMeeting(appName: "Teams", windowTitle: "Design review")
        for phase in [
            MeetingPhase.idle, .detected(detected), .completed("Sync"), .failed("Earlier failure"),
        ] {
            try RecordingIntentRules.checkCanStart(phase)
        }
    }

    @Test
    func finishingPausingOrFlaggingWithNothingRecordingFailsClearly() {
        for phase in [MeetingPhase.idle, .processing(.saving), .completed("Sync")] {
            #expect(throws: NookIntentError.notRecording) {
                try RecordingIntentRules.checkIsRecording(phase)
            }
            #expect(throws: NookIntentError.notRecording) {
                try RecordingIntentRules.checkCanTogglePause(phase, transitionInFlight: false)
            }
        }
        #expect(NookIntentError.notRecording.message == "Nook is not recording right now.")
    }

    @Test
    func aPauseRequestDuringAPauseChangeIsRefusedRatherThanMisreported() throws {
        let recording = MeetingPhase.recording(title: "Sync", startedAt: Date())
        #expect(throws: NookIntentError.pauseChanging) {
            try RecordingIntentRules.checkCanTogglePause(recording, transitionInFlight: true)
        }
        try RecordingIntentRules.checkCanTogglePause(recording, transitionInFlight: false)
        #expect(RecordingIntentRules.pauseDialog(wasPaused: false) == "Recording paused.")
        #expect(RecordingIntentRules.pauseDialog(wasPaused: true) == "Recording resumed.")
    }

    @Test
    func sayingPauseToAPausedRecordingNeverResumesIt() {
        #expect(
            RecordingIntentRules.alreadySettled(.pause, isPaused: true)
                == "The recording is already paused."
        )
        #expect(
            RecordingIntentRules.alreadySettled(.resume, isPaused: false)
                == "The recording is not paused."
        )
        #expect(RecordingIntentRules.alreadySettled(.pause, isPaused: false) == nil)
        #expect(RecordingIntentRules.alreadySettled(.resume, isPaused: true) == nil)
        // Saved Shortcuts from before the choice existed keep toggling.
        #expect(RecordingIntentRules.alreadySettled(.toggle, isPaused: true) == nil)
        #expect(RecordingIntentRules.alreadySettled(.toggle, isPaused: false) == nil)
    }

    @Test
    func aStartReportsWhatActuallyHappened() {
        #expect(
            RecordingIntentRules.startOutcome(after: .recording(title: "Sync", startedAt: Date()))
                == .recording
        )
        #expect(RecordingIntentRules.startOutcome(after: .processing(.preparing)) == .preparing)
        #expect(
            RecordingIntentRules.startOutcome(after: .failed("Microphone permission is required."))
                == .failed("Microphone permission is required.")
        )
    }

    @Test
    func everyActionFailureReadsAsPlainCopy() {
        let errors: [NookIntentError] = [
            .alreadyRecording, .busyWithRecording, .notRecording, .pauseChanging,
            .noMeetings, .noSummary(title: "Weekly sync"), .meetingUnavailable,
            .emptyQuestion,
        ]
        for error in errors {
            #expect(!error.message.isEmpty)
            #expect(!error.message.contains("\u{2014}"), "\(error.message)")
            #expect(error.message.hasSuffix("."), "\(error.message)")
            #expect(String(localized: error.localizedStringResource) == error.message)
        }
        #expect(NookIntentError.noSummary(title: "Weekly sync").message.contains("Weekly sync"))
    }

    // MARK: - Latest meeting summary

    @Test
    func theLatestSummaryComesFromTheNewestMeetingNotANoteOrDigest() throws {
        let notes = [
            note("Shopping list", kind: .spoken, daysAgo: 0),
            note("This week", kind: .digest, daysAgo: 0.5),
            note("Design review", daysAgo: 1, summary: "  Shipped the notch.  "),
            note("Kickoff", daysAgo: 3),
        ]
        let latest = try #require(IntentLibrary.latestMeeting(in: notes))
        #expect(latest.title == "Design review")
        #expect(try IntentLibrary.summary(of: latest) == "Shipped the notch.")
    }

    @Test
    func copiesSharingAnIDAreNotTakenForTheLatestMeeting() {
        let shared = UUID()
        let notes = [
            note("Copy one", id: shared, daysAgo: 0),
            note("Copy two", id: shared, daysAgo: 0),
            note("Planning", daysAgo: 2),
        ]
        #expect(IntentLibrary.latestMeeting(in: notes)?.title == "Planning")
    }

    @Test
    func aLibraryWithoutMeetingsOrSummariesSaysWhatIsMissing() {
        #expect(IntentLibrary.latestMeeting(in: [note("List", kind: .spoken, daysAgo: 0)]) == nil)
        #expect(throws: NookIntentError.noSummary(title: "Standup")) {
            try IntentLibrary.summary(of: note("Standup", daysAgo: 0, summary: "  \n"))
        }
    }

    // MARK: - Open action items

    @Test
    func openActionItemsAreReadOutAndLongListsAreSummarised() {
        #expect(IntentLibrary.openActionsDialog([]) == "You have no open action items.")
        #expect(
            IntentLibrary.openActionsDialog(["Send the deck"])
                == "You have 1 open action item:\n\u{2022} Send the deck"
        )
        let items = (1...7).map { "Item \($0)" }
        let dialog = IntentLibrary.openActionsDialog(items)
        #expect(dialog.hasPrefix("You have 7 open action items:"))
        #expect(dialog.contains("\u{2022} Item 5"))
        #expect(!dialog.contains("Item 6"))
        #expect(dialog.hasSuffix("And 2 more."))
    }

    // MARK: - Ask your library

    private func citation(_ number: Int, _ title: String, noteID: UUID = UUID()) -> LibraryCitation {
        LibraryCitation(
            number: number,
            chunk: LibraryChunk(
                noteID: noteID,
                noteTitle: title,
                startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                label: "Decision",
                text: "Synthetic passage."
            )
        )
    }

    @Test
    func anAnswerKeepsItsSourcesAndNamesTheMeetingsAloud() throws {
        let launch = UUID()
        let citations = [
            citation(1, "Launch review", noteID: launch),
            citation(2, "Pricing sync"),
            citation(3, "Launch review", noteID: launch),
        ]
        let reply = try LibraryAskReply(LibraryAnswer(
            text: "Launch moved to Friday [1]. Pricing stays flat [2][3].",
            citations: citations,
            refusedReason: nil
        ))
        #expect(reply.text.hasPrefix("Launch moved to Friday [1]. Pricing stays flat [2][3]."))
        for source in citations {
            #expect(reply.text.contains("[\(source.number)] \(source.displayTitle)"))
        }
        #expect(
            reply.spoken
                == "Launch moved to Friday. Pricing stays flat.\n\nFrom \u{201C}Launch review\u{201D}, \u{201C}Pricing sync\u{201D}."
        )
    }

    @Test
    func aWeakMatchIsRefusedHonestlyInsteadOfAnswered() {
        let reason = "Nothing in your notes matches that closely enough to answer."
        #expect(throws: NookIntentError.noAnswer(reason)) {
            try LibraryAskReply(LibraryAnswer(text: "", citations: [], refusedReason: reason))
        }
        #expect(throws: NookIntentError.emptyQuestion) {
            try LibraryAskReply(LibraryAnswer(text: "", citations: [], refusedReason: ""))
        }
        #expect(throws: NookIntentError.self) {
            try LibraryAskReply(LibraryAnswer(text: " ", citations: [], refusedReason: nil))
        }
    }

    @Test
    func passagesShownWhenTheModelIsUnavailableAreStillReturned() throws {
        let fallback = "The on-device model was unavailable, so here are the closest passages instead:\n\n[1] Decision: Ship it."
        let reply = try LibraryAskReply(LibraryAnswer(
            text: fallback,
            citations: [citation(1, "Launch review")],
            refusedReason: nil
        ))
        #expect(reply.text.hasPrefix(fallback))
        #expect(reply.spoken.contains("Decision: Ship it."))
        #expect(!reply.spoken.contains("[1]"))
    }

    // MARK: - Meetings as Shortcuts parameters

    @Test
    func findingAMeetingMatchesEveryWordOfItsTitleNewestFirst() {
        let notes = [
            note("Budget sync", daysAgo: 1),
            note("Q3 Budget Review", daysAgo: 5),
            note("Review of the budget", daysAgo: 2),
            note("Hiring", daysAgo: 0),
        ]
        let titles = MeetingEntityQuery.matching("budget REVIEW", in: notes).map(\.title)
        #expect(titles == ["Review of the budget", "Q3 Budget Review"])
    }

    @Test
    func suggestedMeetingsAreTheMostRecentAndLeaveOutAmbiguousCopies() {
        let shared = UUID()
        let notes = [
            note("Old", daysAgo: 9),
            note("Copy", id: shared, daysAgo: 0),
            note("Copy", id: shared, daysAgo: 0),
            note("Newest", daysAgo: 1),
            note("Middle", daysAgo: 4),
        ]
        let titles = MeetingEntityQuery.matching("", in: notes, limit: 2).map(\.title)
        #expect(titles == ["Newest", "Middle"])
        #expect(MeetingEntityQuery.matching("copy", in: notes).isEmpty)
    }

    @Test
    func aSavedShortcutFindsItsMeetingsByIDAndDropsOnesThatAreGone() {
        let first = note("First", daysAgo: 1)
        let second = note("Second", daysAgo: 2)
        let shared = UUID()
        let notes = [first, second, note("A", id: shared, daysAgo: 3), note("B", id: shared, daysAgo: 3)]
        let found = MeetingEntityQuery.notes(withIDs: [second.id, UUID(), shared, first.id], in: notes)
        #expect(found.map(\.title) == ["Second", "First"])
        #expect(MeetingEntity(note: second).id == second.id)
    }
}
