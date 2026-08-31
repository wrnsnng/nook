import Foundation
import Testing
@testable import Nook

@MainActor
struct LibraryAskLifecycleTests {
    @Test
    func draftingAnotherQuestionKeepsTheAnswerAttachedToItsSubmission() async throws {
        let responses = ControlledLibraryAskResponses()
        let session = LibraryAskSession(answerer: responses.answer)
        let id = UUID()
        var notes = [
            MeetingNote(
                id: id, title: "Original meeting", startedAt: Date(timeIntervalSince1970: 1_000),
                endedAt: Date(timeIntervalSince1970: 1_100), sourceApp: "Synthetic", summary: "Original summary."
            ),
            MeetingNote(
                id: id, title: "Copied meeting", startedAt: Date(timeIntervalSince1970: 1_001),
                endedAt: Date(timeIntervalSince1970: 1_101), sourceApp: "Synthetic", summary: "Copied summary."
            )
        ]
        notes[0].fileURL = URL(fileURLWithPath: "/synthetic/first/meeting.md")
        notes[1].fileURL = URL(fileURLWithPath: "/synthetic/second/meeting.md")
        let submittedIdentities = notes.map(\.libraryIdentity)
        session.question = "  What did we decide?\n"
        let task = try #require(session.ask(notes: notes))
        notes[0].title = "Changed after submission"
        await responses.waitForRequests(1)

        session.question = "What should we discuss next?"
        #expect(session.isAnswering)
        #expect(!session.canAsk)
        #expect(session.ask(notes: []) == nil)
        #expect(session.submittedQuestion == "What did we decide?")
        #expect(responses.requests.count == 1)
        #expect(responses.requests[0].question == "What did we decide?")
        #expect(responses.requests[0].notes.map(\.libraryIdentity) == submittedIdentities)
        #expect(responses.requests[0].notes[0].title == "Original meeting")

        let citation = LibraryCitation(number: 1, chunk: LibraryChunk(
            noteID: id, noteTitle: "Original meeting", startedAt: Date(timeIntervalSince1970: 1_000),
            label: "Decision", text: "A synthetic release decision."
        ))
        responses.finish(0, with: LibraryAskSession.Response(answer: LibraryAnswer(
            text: "The recorded decision. [1]", citations: [citation], refusedReason: nil
        )))
        await task.value

        #expect(session.submittedQuestion == "What did we decide?")
        #expect(session.answer?.text == "The recorded decision. [1]")
        #expect(session.answer?.citations == [citation])
        #expect(session.question == "What should we discuss next?")
        #expect(session.canAsk)
        #expect(!session.isAnswering)
    }

    @Test
    func refusalsAndErrorsBelongToTheSubmittedQuestionAndClearOnRetry() async throws {
        let session = LibraryAskSession { question, _ in
            if question == "First question" {
                return LibraryAskSession.Response(
                    answer: LibraryAnswer(text: "", citations: [], refusedReason: "No matching notes."),
                    errorMessage: "Synthetic search failure."
                )
            }
            return Self.response("Answer to the second question")
        }
        session.question = "First question"
        let first = try #require(session.ask(notes: []))
        session.question = "Second question"
        await first.value

        #expect(session.submittedQuestion == "First question")
        #expect(session.answer?.refusedReason == "No matching notes.")
        #expect(session.errorMessage == "Synthetic search failure.")
        #expect(session.question == "Second question")

        let retry = try #require(session.ask(notes: []))
        #expect(session.submittedQuestion == "Second question")
        #expect(session.answer == nil)
        #expect(session.errorMessage == nil)
        await retry.value
        #expect(session.answer?.text == "Answer to the second question")
        #expect(session.errorMessage == nil)
    }

    @Test(arguments: ["A different question", "Original question"])
    func disappearanceInvalidatesNoncooperativeAnswersWithoutLosingTheRetryDraft(
        retryQuestion: String
    ) async throws {
        let responses = ControlledLibraryAskResponses()
        let session = LibraryAskSession(answerer: responses.answer)
        session.question = "Original question"
        let first = try #require(session.ask(notes: []))
        await responses.waitForRequests(1)

        let exactDraft = "  \(retryQuestion)\n"
        session.question = exactDraft
        // The view invokes the same invalidation when its parent dismisses it.
        session.cancel()
        #expect(session.question == exactDraft)
        #expect(session.submittedQuestion == nil)
        #expect(session.answer == nil)
        #expect(!session.isAnswering)
        #expect(session.canAsk)

        let retry = try #require(session.ask(notes: []))
        await responses.waitForRequests(2)
        responses.finish(1, with: Self.response("Current answer"))
        await retry.value

        // This fake deliberately ignores cancellation and produces a late
        // error/result, including when both requests have the same question.
        responses.finish(0, with: LibraryAskSession.Response(
            answer: LibraryAnswer(text: "Old answer", citations: [], refusedReason: nil),
            errorMessage: "Old failure"
        ))
        await first.value

        #expect(responses.cancelledRequests[0] == true)
        #expect(responses.cancelledRequests[1] == false)
        #expect(session.submittedQuestion == retryQuestion)
        #expect(session.answer?.text == "Current answer")
        #expect(session.errorMessage == nil)
        #expect(session.question == exactDraft)
        #expect(!session.isAnswering)
    }

    @Test
    func cancellationBeforeTheTaskStartsDoesNotInvokeTheAnswerer() async throws {
        let invocations = LibraryAskInvocationCounter()
        let session = LibraryAskSession { _, _ in
            invocations.count += 1
            return Self.response("An unnecessary answer")
        }
        session.question = "Keep this draft"
        let task = try #require(session.ask(notes: []))
        session.cancel()
        await task.value

        #expect(invocations.count == 0)
        #expect(session.question == "Keep this draft")
        #expect(session.answer == nil)
        #expect(session.canAsk)
    }

    @Test
    func releasingTheSessionCancelsItsActiveWork() async throws {
        let responses = ControlledLibraryAskResponses()
        var session: LibraryAskSession? = LibraryAskSession(answerer: responses.answer)
        let sessionWasReleased = { [weak session] in session == nil }
        session?.question = "A synthetic question"
        let task = try #require(session?.ask(notes: []))
        await responses.waitForRequests(1)
        session = nil
        #expect(sessionWasReleased())

        responses.finish(0, with: Self.response("A response after teardown"))
        await task.value
        #expect(responses.cancelledRequests[0] == true)
    }

    @Test
    func whitespaceOnlyInputNeverStartsWork() async {
        let responses = ControlledLibraryAskResponses()
        let session = LibraryAskSession(answerer: responses.answer)
        session.question = " \t\n "
        #expect(!session.canAsk)
        #expect(session.ask(notes: []) == nil)
        #expect(responses.requests.isEmpty)
        #expect(session.question == " \t\n ")
    }

    private static func response(_ text: String) -> LibraryAskSession.Response {
        LibraryAskSession.Response(answer: LibraryAnswer(text: text, citations: [], refusedReason: nil))
    }
}

@MainActor
private final class LibraryAskInvocationCounter {
    var count = 0
}

/// A continuation-controlled answerer intentionally ignores cancellation, so
/// stale-result assertions do not depend on a model, timer or cooperative SDK.
@MainActor
private final class ControlledLibraryAskResponses {
    struct Request {
        let question: String
        let notes: [MeetingNote]
    }

    private(set) var requests: [Request] = []
    private(set) var cancelledRequests: [Int: Bool] = [:]
    private var pending: [Int: CheckedContinuation<LibraryAskSession.Response, Never>] = [:]
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func answer(question: String, notes: [MeetingNote]) async -> LibraryAskSession.Response {
        let index = requests.count
        let response: LibraryAskSession.Response = await withCheckedContinuation { continuation in
            pending[index] = continuation
            requests.append(Request(question: question, notes: notes))
            let ready = waiters.filter { $0.count <= requests.count }
            waiters.removeAll { $0.count <= requests.count }
            for waiter in ready { waiter.continuation.resume() }
        }
        cancelledRequests[index] = Task.isCancelled
        return response
    }

    func waitForRequests(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    func finish(_ index: Int, with response: LibraryAskSession.Response) {
        pending.removeValue(forKey: index)?.resume(returning: response)
    }
}
