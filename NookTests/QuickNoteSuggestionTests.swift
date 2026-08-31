import Foundation
import Testing
@testable import Nook

/// A suggestion must belong to the current words, but its parsing must never
/// hold up preservation of those words or queue every intermediate edit.
@MainActor
struct QuickNoteSuggestionTests {
    private func withPad(
        _ operation: @MainActor (QuickNoteController, MarkdownStore, DraftJournal, SuggestionGate) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NookSuggestion-\(UUID().uuidString)")
        let library = root.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MarkdownStore(noteLoader: { _, _ in .success((notes: [], issues: [])) })
        store.storageURL = library
        let journal = DraftJournal(directoryURL: root.appendingPathComponent("Drafts"))
        let gate = SuggestionGate()
        let pad = QuickNoteController(
            store: store, recovery: journal,
            suggestTask: { await gate.suggest($0) }
        )
        do { try await operation(pad, store, journal, gate) }
        catch { await gate.finish(); throw error }
        await gate.finish()
        await journal.flush()
    }

    private func calls(_ minimum: Int, on gate: SuggestionGate) async throws -> [String] {
        let result = await withDeadline(seconds: 5) { await gate.waitForCalls(minimum) }
        let inputs = try #require(result)
        try #require(inputs.count >= minimum)
        return inputs
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(predicate(), "The worker should publish its current result.")
    }

    @Test
    func aBurstKeepsOnlyTheActiveAndNewestSuggestionRequests() async throws {
        try await withPad { pad, _, _, gate in
            pad.text = "First task tomorrow"
            _ = try await calls(1, on: gate)
            for index in 0..<30 { pad.text = "Updated task \(index) tomorrow" }
            let latest = pad.text
            #expect(pad.taskSuggestion == nil)
            await gate.release(0)
            let inputs = try await calls(2, on: gate)
            #expect(inputs == ["First task tomorrow", latest])
            #expect(pad.taskSuggestion == nil)
            #expect(await gate.maximumActive == 1)
            await gate.release(1)
            try await waitUntil { pad.taskSuggestion?.paragraph == latest }
        }
    }

    @Test(arguments: [false, true])
    func supersededResultsCannotOfferTasksForEquivalentOrRestoredWords(clearFirst: Bool) async throws {
        try await withPad { pad, _, _, gate in
            let original = "Caf\u{00E9} tomorrow"
            pad.text = original
            _ = try await calls(1, on: gate)
            if clearFirst { pad.text = "" }
            pad.text = clearFirst ? original : "Cafe\u{0301} tomorrow"
            let expected = Data(pad.text.utf8)
            await gate.release(0)
            _ = try await calls(2, on: gate)
            #expect(pad.taskSuggestion == nil)
            await gate.release(1)
            try await waitUntil { pad.taskSuggestion != nil }
            #expect(pad.taskSuggestion.map { Data($0.paragraph.utf8) } == expected)
        }
    }

    @Test
    func countingCheckpointingAndSavingDoNotWaitForSuggestions() async throws {
        try await withPad { pad, _, journal, gate in
            pad.text = "Keep these café notes tomorrow"
            _ = try await calls(1, on: gate)
            #expect(pad.wordCount == 5)
            #expect(pad.taskSuggestion == nil)
            await journal.flush()
            let restarted = DraftJournal(directoryURL: journal.directoryURL)
            await restarted.scan()
            #expect(restarted.recoveredDrafts.first.map { Data($0.text.utf8) } == Data(pad.text.utf8))
            let saved = try #require(pad.saveIfNeeded())
            let file = try #require(saved.fileURL)
            #expect(try Data(contentsOf: file) == Data(MarkdownCodec.encode(saved).utf8))
            #expect(!pad.hasUnsavedEdits)
            #expect(pad.taskSuggestion == nil)
        }
    }

    @Test
    func anOldVisibleActionCannotRewriteNewerWords() async throws {
        try await withPad { pad, _, _, gate in
            pad.text = "Send café notes tomorrow"
            _ = try await calls(1, on: gate)
            await gate.release(0)
            try await waitUntil { pad.taskSuggestion != nil }
            let old = try #require(pad.taskSuggestion)
            pad.text += " after review"
            let expected = Data(pad.text.utf8)
            pad.applyTaskSuggestion(old)
            #expect(Data(pad.text.utf8) == expected)
            #expect(pad.taskSuggestion == nil)
            _ = try await calls(2, on: gate)
            await gate.release(1)
            try await waitUntil { pad.taskSuggestion != nil }
            pad.applyTaskSuggestion(try #require(pad.taskSuggestion))
            #expect(pad.text.hasPrefix("- [ ] Send café notes tomorrow after review [due: "))
            #expect(pad.taskSuggestion == nil)
        }
    }

    @Test
    func reopeningRefreshesTheDateWithoutHidingTheCurrentCount() async throws {
        try await withPad { pad, _, _, gate in
            pad.text = "Ship tomorrow"
            _ = try await calls(1, on: gate)
            await gate.release(0)
            try await waitUntil { pad.taskSuggestion != nil }
            let first = try #require(pad.taskSuggestion)
            #expect(pad.wordCount == 2)
            pad.refreshTaskSuggestion()
            #expect(pad.wordCount == 2)
            #expect(pad.taskSuggestion == nil)
            _ = try await calls(2, on: gate)
            await gate.release(1, daysLater: 1)
            try await waitUntil { pad.taskSuggestion != nil }
            #expect(pad.taskSuggestion?.dueDate != first.dueDate)
            #expect(pad.wordCount == 2)
        }
    }

    @Test
    func releasingTheControllerCancelsAnActiveSuggestion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NookSuggestionLifetime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MarkdownStore(noteLoader: { _, _ in .success((notes: [], issues: [])) })
        store.storageURL = root
        let gate = SuggestionGate()
        var pad: QuickNoteController? = QuickNoteController(store: store, suggestTask: { await gate.suggest($0) })
        pad?.text = "Ship tomorrow"
        _ = try await calls(1, on: gate)
        pad = nil
        let cancelled = await withDeadline(seconds: 5) { await gate.waitForCancellation() }
        await gate.finish()
        #expect(cancelled == true)
    }
}

private actor SuggestionGate {
    private var inputs: [String] = []
    private var pending: [Int: CheckedContinuation<QuickCaptureTaskParser.Suggestion?, Never>] = [:]
    private var callWaiters: [(Int, CheckedContinuation<[String], Never>)] = []
    private var cancellationWaiters: [CheckedContinuation<Bool, Never>] = []
    private var finished = false
    private var cancelled = false
    private(set) var maximumActive = 0

    func suggest(_ text: String) async -> QuickCaptureTaskParser.Suggestion? {
        guard !finished else { return nil }
        let index = inputs.count
        inputs.append(text)
        return await withTaskCancellationHandler {
            if Task.isCancelled { cancel() }
            return await withCheckedContinuation { continuation in
                guard !finished, !cancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                pending[index] = continuation
                maximumActive = max(maximumActive, pending.count)
                let ready = callWaiters.filter { $0.0 <= inputs.count }
                callWaiters.removeAll { $0.0 <= inputs.count }
                for (_, waiter) in ready { waiter.resume(returning: inputs) }
            }
        } onCancel: { Task { await self.cancel() } }
    }

    func release(_ index: Int, daysLater: Int = 0) {
        let now = Date(timeIntervalSince1970: 1_789_000_000 + Double(daysLater) * 86_400)
        pending.removeValue(forKey: index)?.resume(returning: QuickCaptureTaskParser.suggestion(in: inputs[index], now: now))
    }

    func waitForCalls(_ minimum: Int) async -> [String] {
        guard inputs.count < minimum, !finished else { return inputs }
        return await withCheckedContinuation { callWaiters.append((minimum, $0)) }
    }

    func waitForCancellation() async -> Bool {
        if cancelled { return true }
        return await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    private func cancel() {
        cancelled = true
        for waiter in cancellationWaiters { waiter.resume(returning: true) }
        cancellationWaiters.removeAll()
        let outstanding = Array(pending.values)
        pending.removeAll()
        for waiter in outstanding { waiter.resume(returning: nil) }
    }

    func finish() {
        finished = true
        cancel()
        for (_, waiter) in callWaiters { waiter.resume(returning: inputs) }
        callWaiters.removeAll()
    }
}
