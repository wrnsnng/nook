import Foundation
import Synchronization
import Testing
@testable import Nook

struct PaletteSearchTests {
    private func note(_ title: String, summary: String = "") -> MeetingNote {
        MeetingNote(
            title: title,
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            endedAt: Date(timeIntervalSince1970: 1_780_000_060),
            sourceApp: "Synthetic", summary: summary
        )
    }

    @Test(arguments: ["rr", "rsrch revw", "reserach", "researh", "RESEARCH"])
    func abbreviationsAndTyposFindTheIntendedTitle(query: String) {
        let target = note("Research review")
        let unrelated = note("Budget planning")
        #expect(CommandPaletteNoteOrder.ordered([unrelated, target], matching: query)
            .map(\.id) == [target.id])
    }

    @Test
    func exactTitleMatchesLeadFuzzyTitlesAndContent() {
        let exact = note("Research")
        let substring = note("Earlier research")
        let fuzzy = note("Reserach")
        let content = note("Unrelated title", summary: "Research")
        #expect(CommandPaletteNoteOrder.ordered(
            [content, fuzzy, substring, exact], matching: "research"
        ).map(\.id) == [exact.id, substring.id, fuzzy.id, content.id])
    }

    @Test
    func allPortableContentCanBeFoundWithoutChangingItsWords() {
        var target = note("Synthetic meeting")
        target.keyPoints = ["Orchid milestone"]
        target.decisions = ["Copper release"]
        target.actionItems = ["Schedule a harbour visit"]
        target.personalNotes = "Granite observations"
        target.transcript = [TranscriptSegment(
            startTime: 0, duration: 4, text: "Telescope calibration", source: .microphone
        )]
        let original = target
        for query in ["orchdi", "coppre", "harbur", "granite", "telesocpe", "telescope synthetic"] {
            #expect(CommandPaletteNoteOrder.ordered([target], matching: query).map(\.id) == [target.id])
        }
        #expect(target == original)
    }

    @Test(arguments: ["cafe", "Cafe\u{0301}", "ＣＡＦＥ", "日本語", "👩🏽‍💻"])
    func matchingRespectsUnicodeWordsAndGraphemes(query: String) {
        let target = note("Café 日本語 👩🏽‍💻")
        #expect(CommandPaletteNoteOrder.ordered([target], matching: query).map(\.id) == [target.id])
    }

    @Test
    func shortQueriesDoNotFuzzilyMatchScatteredTranscriptLetters() {
        let target = note("Synthetic", summary: "Rare events arise regularly")
        #expect(CommandPaletteNoteOrder.ordered([target], matching: "rr").isEmpty)
        #expect(CommandPaletteNoteOrder.ordered([target], matching: "zzzzzz").isEmpty)
    }

    @Test
    func fullLengthQueriesAndLateTranscriptWordsAreNotTruncated() {
        let longWord = String(repeating: "synthetic", count: 12)
        let target = note("Meeting", summary: String(repeating: "plain words ", count: 20_000) + longWord)
        #expect(CommandPaletteNoteOrder.ordered([target], matching: longWord).map(\.id) == [target.id])
    }

    @Test(arguments: [false, true])
    func cancellationDuringTranscriptComparisonRejectsAlreadyRankedNotes(useCache: Bool) {
        let earlier = note("Telesocpe")
        let target = note("Meeting", summary: String(repeating: "orchid ", count: 256) + "telescope")
        let documents = useCache ? [
            earlier.libraryIdentity: LibrarySearchController.document(for: earlier),
            target.libraryIdentity: LibrarySearchController.document(for: target),
        ] : nil
        let checks = Mutex(0)
        // Cancel at a deterministic checkpoint within the long word scan,
        // without relying on how quickly a loaded CI host schedules a Task.
        let result = CommandPaletteNoteOrder.ordered(
            [earlier, target], matching: "telesocpe", documents: documents,
            isCancelled: {
                checks.withLock { count in
                    count += 1
                    return count >= 32
                }
            }
        )
        #expect(checks.withLock { $0 } >= 32)
        #expect(checks.withLock { $0 } < 40)
        #expect(result.isEmpty)
    }

    @Test
    func cachedContentKeepsCopiedFilesAndSameTimestampRevisionsDistinct() async {
        var first = note("Copy", summary: "Orchid")
        first.fileURL = URL(fileURLWithPath: "/synthetic/a.md")
        first.fileRevision = MeetingNote.contentRevision(Data("first".utf8))
        var second = first
        second.fileURL = URL(fileURLWithPath: "/synthetic/b.md")
        second.summary = "Granite"
        second.fileRevision = MeetingNote.contentRevision(Data("second".utf8))
        let cache = SearchDocumentCache()
        var documents = await cache.documents(for: [first, second])
        #expect(CommandPaletteNoteOrder.ordered([first, second], matching: "graniet", documents: documents)
            .map(\.libraryIdentity) == [second.libraryIdentity])
        second.summary = "Telescope"
        second.fileRevision = MeetingNote.contentRevision(Data("changed".utf8))
        documents = await cache.documents(for: [first, second])
        #expect(CommandPaletteNoteOrder.ordered([first, second], matching: "graniet", documents: documents).isEmpty)
        #expect(CommandPaletteNoteOrder.ordered([first, second], matching: "telescop", documents: documents)
            .map(\.libraryIdentity) == [second.libraryIdentity])
    }

    @Test @MainActor
    func aNewQuerySelectsItsFirstAsyncResultWithoutOverridingAChoice() {
        let item = CommandPaletteItem(
            id: "synthetic", symbol: "doc", title: "Synthetic", subtitle: nil,
            destination: .verb, perform: {}
        )
        let other = CommandPaletteItem(
            id: "other", symbol: "doc", title: "Other", subtitle: nil,
            destination: .verb, perform: {}
        )
        var selection = CommandPaletteSelection()
        selection.beginSearch()
        selection.refresh(in: [], selectFirst: true)
        selection.finishSearch(in: [item, other])
        #expect(selection.itemID == item.id)
        selection.beginSearch()
        selection.select(other)
        selection.finishSearch(in: [item, other])
        #expect(selection.itemID == other.id)
        selection.refresh(in: [item])
        selection.finishSearch(in: [item])
        #expect(selection.itemID == nil)
    }

    @Test @MainActor
    func actualSearchPublishesTranscriptMatchesAndEmptyQueriesRestoreRecentNotes() async throws {
        let target = note("Meeting", summary: "Telescope calibration")
        let controller = CommandPaletteSearchController()
        controller.update(query: "telesocpe", notes: [target])
        try await waitUntil { !controller.isSearching }
        #expect(controller.matches.map(\.id) == [target.id])
        controller.update(query: "   ", notes: [target])
        #expect(!controller.isSearching)
        #expect(controller.matches.map(\.id) == [target.id])
    }

    @Test(arguments: [false, true]) @MainActor
    func closingOrChangingLibrariesRejectsALateUncooperativeMatcher(close: Bool) async throws {
        let gate = PaletteMatcherGate()
        let old = note("Old library")
        let current = note("Current library")
        let controller = CommandPaletteSearchController { query, notes, _ in
            if query == "old" { await gate.pause() }
            return notes
        }
        let oldSearch = controller.update(query: "old", notes: [old])
        try await waitUntil { await gate.started }
        if close {
            controller.cancel()
        } else {
            controller.update(query: "current", notes: [current])
            try await waitUntil { !controller.isSearching }
        }
        await gate.release()
        // The actor gate deliberately ignores cancellation, exercising the
        // controller's ownership check after the worker eventually returns.
        await oldSearch?.value
        #expect(!controller.isSearching)
        #expect(controller.matches.map(\.id) == (close ? [] : [current.id]))
    }

    @MainActor
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition())
    }
}

private actor PaletteMatcherGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func pause() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
