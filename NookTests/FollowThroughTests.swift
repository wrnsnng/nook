import Foundation
import Testing
@testable import Nook

struct FollowThroughTests {
    // MARK: Owners

    @Test(arguments: [
        ("Maya — refine the first-run copy", "Maya", "refine the first-run copy"),
        ("Leo – validate the permission sequence", "Leo", "validate the permission sequence"),
        ("Ana Silva: prepare five usability sessions", "Ana Silva", "prepare five usability sessions"),
        ("@priya send the scope doc", "priya", "send the scope doc"),
        ("Maya will send the brief", "Maya", "send the brief"),
    ])
    func anOwnerWrittenTheUsualWaysIsRecognised(
        _ item: String, _ owner: String, _ task: String
    ) {
        let parsed = ActionItemOwner.parse(item)
        #expect(parsed.owner == owner)
        #expect(parsed.task == task)
    }

    /// A row showing the owner separately starts its task with a capital;
    /// an item with no owner is shown exactly as written.
    @Test
    func tasksShownBesideTheirOwnerReadAsSentences() {
        #expect(ActionItemOwner.parse("Maya: refine the copy").displayTask == "Refine the copy")
        #expect(ActionItemOwner.parse("book the room").displayTask == "book the room")
    }

    /// Labels people put in front of items, lowercase phrases and pronouns
    /// are not people, and an item nobody named keeps its wording.
    @Test(arguments: [
        "TODO: book the room",
        "Next steps: share the deck",
        "Send the revised brief by Friday",
        "Follow up with legal - after launch",
        "We will send the brief",
        "Budget review: confirm numbers",
    ])
    func itemsWithoutAPersonHaveNoOwner(_ item: String) {
        let parsed = ActionItemOwner.parse(item)
        #expect(parsed.owner == nil)
        #expect(parsed.task == item)
    }

    // MARK: Follow-up draft

    private func note() -> MeetingNote {
        var note = MeetingNote(
            id: UUID(),
            title: "Design review",
            startedAt: Date(timeIntervalSince1970: 1_790_000_000),
            endedAt: Date(timeIntervalSince1970: 1_790_001_800),
            sourceApp: "Teams",
            summary: "The team agreed on a calmer onboarding.\n\nLonger detail that stays in the note.",
            keyPoints: [],
            decisions: ["Prototype the three-step onboarding"],
            actionItems: [
                "Maya — refine the first-run copy [due: 2026-09-30]",
                "Leo: validate permissions",
                "Book the usability room",
            ],
            personalNotes: "",
            transcript: []
        )
        note.openQuestions = ["Who owns the launch email?"]
        note.completedActionItems = ["Book the usability room"]
        return note
    }

    /// The recap leads with the gist, lists decisions and what is still to
    /// do with owners and dates, and leaves out finished items.
    @Test
    func anEmailRecapCarriesDecisionsOwnersAndOpenQuestions() {
        let draft = FollowUpDraft.make(from: note(), format: .email)

        #expect(draft.subject == "Recap: Design review")
        #expect(draft.body.contains("The team agreed on a calmer onboarding."))
        #expect(!draft.body.contains("Longer detail"))
        #expect(draft.body.contains("• Prototype the three-step onboarding"))
        #expect(draft.body.contains("• Maya: refine the first-run copy (due Sep 30)"))
        #expect(draft.body.contains("• Leo: validate permissions"))
        #expect(!draft.body.contains("Book the usability room"))
        #expect(draft.body.contains("• Who owns the launch email?"))
    }

    /// Nothing is invented: a note with no structured sections produces a
    /// recap of its summary only, with no empty headings.
    @Test
    func aSparseNoteGivesASparseRecap() {
        var sparse = note()
        sparse.decisions = []
        sparse.actionItems = []
        sparse.openQuestions = []
        let draft = FollowUpDraft.make(from: sparse, format: .chat)

        #expect(draft.body.hasPrefix("*Recap: Design review*"))
        #expect(!draft.body.contains("Decisions"))
        #expect(!draft.body.contains("Next steps"))
        #expect(!draft.body.contains("Still open"))
    }

    /// User-facing copy never uses em-dashes, including text Nook writes.
    @Test(arguments: FollowUpDraft.Format.allCases)
    func recapsContainNoEmDashesOfTheirOwn(_ format: FollowUpDraft.Format) {
        let draft = FollowUpDraft.make(from: note(), format: format)
        #expect(!draft.body.contains("—"))
        #expect(!draft.subject.contains("—"))
    }
}
