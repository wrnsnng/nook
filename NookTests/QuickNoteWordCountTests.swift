import Combine
import Foundation
import Testing
@testable import Nook

/// Counting is advisory. Its queue must never delay preserving the note or
/// make a destructive action trust a total from another text revision.
@MainActor
struct QuickNoteWordCountTests {
    private func fixture() throws -> (directory: URL, store: MarkdownStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NookWordCount-\(UUID().uuidString)")
        let library = directory.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let store = MarkdownStore(noteLoader: { _, _ in .success((notes: [], issues: [])) })
        store.storageURL = library
        return (directory, store)
    }

    private func withCounter(
        _ operation: @MainActor (ControlledWordCounter) async throws -> Void
    ) async throws {
        let counter = ControlledWordCounter()
        do {
            try await operation(counter)
        } catch {
            await counter.finish()
            throw error
        }
        await counter.finish()
    }

    private func calls(
        _ minimum: Int, on counter: ControlledWordCounter
    ) async throws -> [String] {
        let result = await withDeadline(seconds: 5) {
            await counter.waitForCalls(minimum)
        }
        let inputs = try #require(result, "The counting worker should accept the queued text.")
        try #require(inputs.count >= minimum)
        return inputs
    }

    private func waitForCount(_ count: Int, in probe: PublishedWordCounts) async throws {
        let received = await withDeadline(seconds: 5) { await probe.wait(for: count) }
        try #require(received == true, "The current revision should publish its count.")
    }

    @Test
    func countingPreservesTheExistingUnicodeWhitespaceDefinition() {
        let samples: [(String, Int)] = [
            ("", 0), (" \t\r\n", 0), ("One", 1),
            ("Café\t👩🏽‍💻\nnext\u{00A0}step", 4),
            ("one\u{2003}two\u{2028}three\u{2029}four", 4),
            ("don't re-enter 1,234", 3), ("你好世界", 1),
            ("a\u{200B}b", 1), ("Cafe\u{0301} next", 2)
        ]
        for (text, expected) in samples {
            #expect(QuickNoteController.countWords(in: text) == expected)
        }
    }

    @Test
    func countingMatchesThePreviousSplitForWhitespaceAndCombiningClusters() {
        let separators = [
            " ", "\t", "\n", "\r", "\r\n", "\u{000B}", "\u{000C}",
            "\u{0085}", "\u{00A0}", "\u{1680}",
            "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}",
            "\u{2005}", "\u{2006}", "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}",
            "\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}", "\u{3000}"
        ]
        for separator in separators {
            let corpus = [
                separator,
                "one\(separator)two",
                "\(separator)leading\(separator)",
                "left\(separator)\u{0301}right",
                "left\(separator)\u{20DD}right",
                "left\(separator)\u{FE0F}right",
                "\(separator)\u{0301}\(separator)",
                "👩🏽‍💻\(separator)Cafe\u{0301}"
            ]
            for text in corpus {
                // Combining marks can join the preceding whitespace into a
                // Character. The old Character-based split is the oracle;
                // counting whitespace scalars would change this behavior.
                let previousCount = text.split(whereSeparator: \.isWhitespace).count
                #expect(QuickNoteController.countWords(in: text) == previousCount)
            }
        }
    }

    @Test
    func anOlderCountCannotAppearWhileTheNewerWordsAreStillBeingCounted() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try await withCounter { counter in
            let pad = QuickNoteController(store: f.store, countWords: { await counter.count($0) })
            let probe = PublishedWordCounts(pad)
            defer { probe.finish() }
            pad.text = "First"
            _ = try await calls(1, on: counter)
            pad.text = "The replacement thought"
            #expect(pad.wordCount == nil)

            await counter.release(0, returning: 1)
            let inputs = try await calls(2, on: counter)
            #expect(inputs == ["First", "The replacement thought"])
            #expect(pad.wordCount == nil)
            #expect(!probe.values.contains(1))

            await counter.release(1, returning: 3)
            try await waitForCount(3, in: probe)
            #expect(pad.wordCount == 3)
            #expect(pad.text == "The replacement thought")
        }
    }

    @Test
    func aBurstCountsOnlyTheActiveSnapshotAndTheLatestQueuedEdit() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try await withCounter { counter in
            let pad = QuickNoteController(store: f.store, countWords: { await counter.count($0) })
            let probe = PublishedWordCounts(pad)
            defer { probe.finish() }
            pad.text = "Initial snapshot"
            _ = try await calls(1, on: counter)

            // The active call stays suspended throughout the burst. This
            // tests buffering without assuming when detached work starts.
            for index in 1...50 { pad.text = "Replacement \(index)" }
            await counter.release(0, returning: 99)
            let inputs = try await calls(2, on: counter)
            try #require(inputs == ["Initial snapshot", "Replacement 50"])
            #expect(pad.wordCount == nil)
            #expect(!probe.values.contains(99))
            #expect(await counter.maximumActiveCalls == 1)

            await counter.release(1, returning: 2)
            try await waitForCount(2, in: probe)
            #expect(await counter.inputs == inputs)
            #expect(pad.wordCount == 2)
        }
    }

    @Test
    func canonicallyEquivalentUnicodeStillInvalidatesTheOlderByteRevision() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try await withCounter { counter in
            let pad = QuickNoteController(store: f.store, countWords: { await counter.count($0) })
            let probe = PublishedWordCounts(pad)
            defer { probe.finish() }
            let composed = "Caf\u{00E9}"
            let decomposed = "Cafe\u{0301}"
            #expect(composed == decomposed)
            #expect(Data(composed.utf8) != Data(decomposed.utf8))
            pad.text = composed
            _ = try await calls(1, on: counter)
            pad.text = decomposed

            await counter.release(0, returning: 42)
            let inputs = try await calls(2, on: counter)
            #expect(Data(inputs[1].utf8) == Data(decomposed.utf8))
            #expect(pad.wordCount == nil)
            #expect(!probe.values.contains(42))
            await counter.release(1, returning: 1)
            try await waitForCount(1, in: probe)
            #expect(Data(pad.text.utf8) == Data(decomposed.utf8))
        }
    }

    @Test(arguments: [false, true])
    func clearingThenRestoringTheSameWordsStillRejectsTheOldRevision(
        clearByDiscarding: Bool
    ) async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try await withCounter { counter in
            let pad = QuickNoteController(store: f.store, countWords: { await counter.count($0) })
            let probe = PublishedWordCounts(pad)
            defer { probe.finish() }
            let original = "  Same café words\n"
            pad.text = original
            _ = try await calls(1, on: counter)
            if clearByDiscarding { pad.discard() }
            else { pad.text = "" }
            #expect(pad.text.isEmpty)
            #expect(pad.wordCount == 0)
            pad.text = original
            #expect(pad.wordCount == nil)

            // Identical bytes do not make a pre-clear request current again.
            await counter.release(0, returning: 77)
            let inputs = try await calls(2, on: counter)
            try #require(inputs == [original, original])
            #expect(pad.wordCount == nil)
            #expect(!probe.values.contains(77))
            await counter.release(1, returning: 3)
            try await waitForCount(3, in: probe)
            #expect(Data(pad.text.utf8) == Data(original.utf8))
        }
    }

    @Test
    func checkpointingAndSavingCompleteWhileTheCounterIsSuspended() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let journal = DraftJournal(directoryURL: f.directory.appendingPathComponent("Drafts"))
        try await withCounter { counter in
            let pad = QuickNoteController(
                store: f.store, recovery: journal,
                countWords: { await counter.count($0) }
            )
            let original = "  Keep this café thought.\nNext step.\n"
            pad.text = original
            _ = try await calls(1, on: counter)
            await journal.flush()
            let restarted = DraftJournal(directoryURL: journal.directoryURL)
            await restarted.scan()
            let recovered = try #require(restarted.recoveredDrafts.first)
            #expect(Data(recovered.text.utf8) == Data(original.utf8))
            #expect(pad.wordCount == nil)

            let saved = try #require(pad.saveIfNeeded())
            let file = try #require(saved.fileURL)
            #expect(try Data(contentsOf: file) == Data(MarkdownCodec.encode(saved).utf8))
            #expect(!pad.hasUnsavedFailure)
            #expect(Data(pad.text.utf8) == Data(original.utf8))
            #expect(pad.wordCount == nil)
            #expect(await counter.activeCallCount == 1)
            await journal.flush()
            await restarted.scan()
            #expect(restarted.recoveredDrafts.isEmpty)
        }
    }

    @Test
    func aPendingCountCannotBypassDiscardConfirmationForASavedNote() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try await withCounter { counter in
            var confirmations = 0
            var deletionAttempts = 0
            let pad = QuickNoteController(
                store: f.store,
                deleteSavedNote: { _ in deletionAttempts += 1; return false },
                countWords: { await counter.count($0) },
                discardConfirmation: { confirmations += 1; return false }
            )
            let original = "  " + Array(repeating: "word", count: 13).joined(separator: " ") + "\n"
            pad.text = original
            _ = try await calls(1, on: counter)
            let saved = try #require(pad.saveIfNeeded())
            let file = try #require(saved.fileURL)
            let bytes = try Data(contentsOf: file)
            #expect(pad.wordCount == nil)

            pad.discardWithConfirmation()

            #expect(confirmations == 1)
            #expect(deletionAttempts == 0)
            #expect(Data(pad.text.utf8) == Data(original.utf8))
            #expect(try Data(contentsOf: file) == bytes)
            #expect(f.store.notes.count == 1)
        }
    }

    @Test
    func aFailedDiscardKeepsThePendingCountAttachedToTheRetainedWords() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try await withCounter { counter in
            var confirmations = 0
            var deletionAttempts = 0
            let pad = QuickNoteController(
                store: f.store,
                deleteSavedNote: { _ in deletionAttempts += 1; return false },
                countWords: { await counter.count($0) },
                discardConfirmation: { confirmations += 1; return true }
            )
            let probe = PublishedWordCounts(pad)
            defer { probe.finish() }
            let original = "  " + Array(repeating: "word", count: 13).joined(separator: " ") + "\n"
            pad.text = original
            _ = try await calls(1, on: counter)
            let saved = try #require(pad.saveIfNeeded())
            let file = try #require(saved.fileURL)
            let bytes = try Data(contentsOf: file)

            pad.discardWithConfirmation()

            #expect(confirmations == 1)
            #expect(deletionAttempts == 1)
            #expect(pad.hasUnsavedFailure)
            #expect(pad.wordCount == nil)
            await counter.release(0, returning: 13)
            try await waitForCount(13, in: probe)
            #expect(pad.wordCount == 13)
            #expect(pad.hasUnsavedFailure)
            #expect(Data(pad.text.utf8) == Data(original.utf8))
            #expect(try Data(contentsOf: file) == bytes)
        }
    }

    @Test(arguments: [12, 13])
    func discardUsesTheThresholdOnlyAfterTheCurrentCountArrives(_ count: Int) async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try await withCounter { counter in
            var confirmations = 0
            let pad = QuickNoteController(
                store: f.store,
                countWords: { await counter.count($0) },
                discardConfirmation: { confirmations += 1; return false }
            )
            let probe = PublishedWordCounts(pad)
            defer { probe.finish() }
            let original = Array(repeating: "word", count: count).joined(separator: " ")
            pad.text = original
            _ = try await calls(1, on: counter)
            await counter.release(0, returning: count)
            try await waitForCount(count, in: probe)

            pad.discardWithConfirmation()

            #expect(confirmations == (count == 13 ? 1 : 0))
            #expect(pad.text == (count == 13 ? original : ""))
            #expect(pad.wordCount == (count == 13 ? 13 : 0))
        }
    }

    @Test
    func releasingTheControllerCancelsAnActiveCounterAndReleasesItsWorker() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try await withCounter { counter in
            let released = AsyncStream<Void>.makeStream()
            var pad: QuickNoteController?
            do {
                let lifetime = WordCountWorkerLifetime(released: released.continuation)
                pad = QuickNoteController(store: f.store, countWords: { [lifetime] text in
                    let count = await counter.count(text)
                    withExtendedLifetime(lifetime) {}
                    return count
                })
            }
            let weakPad = WeakQuickNoteReference(pad)
            pad?.text = "An active counter"
            _ = try await calls(1, on: counter)
            pad = nil

            let cancelled = await withDeadline(seconds: 5) { await counter.waitForCancellation(0) }
            try #require(cancelled == true, "Controller teardown should cancel its active counting task.")
            let didRelease = await withDeadline(seconds: 5) {
                for await _ in released.stream { return true }
                return false
            }
            #expect(didRelease == true)
            #expect(weakPad.value == nil)
            #expect(await counter.activeCallCount == 0)
        }
    }

    @Test
    func aWorkerWaitingForAnotherEditDoesNotKeepTheControllerAlive() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let released = AsyncStream<Void>.makeStream()
        var pad: QuickNoteController?
        do {
            let lifetime = WordCountWorkerLifetime(released: released.continuation)
            pad = QuickNoteController(store: f.store, countWords: { [lifetime] text in
                let count = QuickNoteController.countWords(in: text)
                withExtendedLifetime(lifetime) {}
                return count
            })
        }
        let weakPad = WeakQuickNoteReference(pad)
        let probe = PublishedWordCounts(try #require(pad))
        defer { probe.finish() }
        pad?.text = "Count then wait"
        try await waitForCount(3, in: probe)
        probe.finish()
        pad = nil

        let didRelease = await withDeadline(seconds: 5) {
            for await _ in released.stream { return true }
            return false
        }
        #expect(didRelease == true)
        #expect(weakPad.value == nil)
    }
}

/// Each invocation suspends independently, so an accidental task per edit
/// exposes concurrent calls instead of hiding them behind the test gate.
private actor ControlledWordCounter {
    private(set) var inputs: [String] = []
    private(set) var maximumActiveCalls = 0
    private var activeCalls: Set<Int> = []
    private var pending: [Int: CheckedContinuation<Int, Never>] = [:]
    private var released: [Int: Int] = [:]
    private var cancelled: Set<Int> = []
    private var callWaiters: [(Int, CheckedContinuation<[String], Never>)] = []
    private var cancellationWaiters: [(Int, CheckedContinuation<Bool, Never>)] = []
    private var isFinished = false

    var activeCallCount: Int { activeCalls.count }

    func count(_ text: String) async -> Int {
        guard !isFinished else { return 0 }
        let index = inputs.count
        inputs.append(text)
        activeCalls.insert(index)
        maximumActiveCalls = max(maximumActiveCalls, activeCalls.count)
        defer { activeCalls.remove(index) }
        let ready = callWaiters.filter { $0.0 <= inputs.count }
        callWaiters.removeAll { $0.0 <= inputs.count }
        for (_, waiter) in ready { waiter.resume(returning: inputs) }
        return await withTaskCancellationHandler {
            if Task.isCancelled { cancel(index) }
            return await withCheckedContinuation { continuation in
                if isFinished || cancelled.contains(index) {
                    continuation.resume(returning: 0)
                } else if let value = released.removeValue(forKey: index) {
                    continuation.resume(returning: value)
                } else {
                    pending[index] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(index) }
        }
    }

    func waitForCalls(_ minimum: Int) async -> [String] {
        guard inputs.count < minimum, !isFinished else { return inputs }
        return await withCheckedContinuation { callWaiters.append((minimum, $0)) }
    }

    func release(_ index: Int, returning value: Int) {
        if let continuation = pending.removeValue(forKey: index) {
            continuation.resume(returning: value)
        } else {
            released[index] = value
        }
    }

    func waitForCancellation(_ index: Int) async -> Bool {
        if cancelled.contains(index) { return true }
        guard !isFinished else { return false }
        return await withCheckedContinuation { cancellationWaiters.append((index, $0)) }
    }

    private func cancel(_ index: Int) {
        cancelled.insert(index)
        pending.removeValue(forKey: index)?.resume(returning: 0)
        let ready = cancellationWaiters.filter { $0.0 == index }
        cancellationWaiters.removeAll { $0.0 == index }
        for (_, waiter) in ready { waiter.resume(returning: true) }
    }

    func finish() {
        isFinished = true
        let outstanding = Array(pending.values)
        pending.removeAll()
        for continuation in outstanding { continuation.resume(returning: 0) }
        for (_, waiter) in callWaiters { waiter.resume(returning: inputs) }
        callWaiters.removeAll()
        for (_, waiter) in cancellationWaiters { waiter.resume(returning: false) }
        cancellationWaiters.removeAll()
    }
}

@MainActor
private final class WeakQuickNoteReference {
    weak var value: QuickNoteController?

    init(_ value: QuickNoteController?) { self.value = value }
}

@MainActor
private final class PublishedWordCounts {
    private(set) var values: [Int?] = []
    private var observation: AnyCancellable?
    private var waiters: [(Int, CheckedContinuation<Bool, Never>)] = []

    init(_ pad: QuickNoteController) {
        observation = pad.$wordCount.sink { [weak self] count in
            guard let self else { return }
            values.append(count)
            let ready = waiters.filter { $0.0 == count }
            waiters.removeAll { $0.0 == count }
            for (_, waiter) in ready { waiter.resume(returning: true) }
        }
    }

    func wait(for count: Int) async -> Bool {
        if values.contains(count) { return true }
        guard observation != nil else { return false }
        return await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func finish() {
        observation?.cancel()
        observation = nil
        for (_, waiter) in waiters { waiter.resume(returning: false) }
        waiters.removeAll()
    }
}

private final class WordCountWorkerLifetime: Sendable {
    private let released: AsyncStream<Void>.Continuation

    init(released: AsyncStream<Void>.Continuation) { self.released = released }

    deinit {
        released.yield(())
        released.finish()
    }
}
