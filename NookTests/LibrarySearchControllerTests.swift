import Combine
import Foundation
import Testing
@testable import Nook

/// Search follows the exact loaded file snapshot. Modification dates and UUIDs
/// alone cannot distinguish an external edit or a copied library's documents.
struct LibrarySearchControllerTests {
    private func note(
        title: String,
        summary: String,
        id: UUID = UUID(),
        fileURL: URL? = URL(fileURLWithPath: "/synthetic/library/note.md"),
        fileModified: Date? = Date(timeIntervalSince1970: 1_000_000)
    ) -> MeetingNote {
        var note = MeetingNote(
            id: id,
            title: title,
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            endedAt: Date(timeIntervalSince1970: 1_780_000_060),
            sourceApp: "Zoom",
            summary: summary,
            fileURL: fileURL,
            fileModified: fileModified
        )
        if fileURL != nil {
            note.fileRevision = MeetingNote.contentRevision(Data(MarkdownCodec.encode(note).utf8))
        }
        return note
    }

    @Test
    func aChangedRevisionInvalidatesSearchEvenWhenTheTimestampIsPreserved() async {
        let cache = SearchDocumentCache()
        let original = note(title: "Design review", summary: "Original wording")
        _ = await cache.documents(for: [original])
        var edited = original
        edited.summary = "Replacement wording"
        edited.fileRevision = MeetingNote.contentRevision(Data(MarkdownCodec.encode(edited).utf8))
        #expect(edited.fileModified == original.fileModified)
        #expect(edited.fileRevision != original.fileRevision)

        let documents = await cache.documents(for: [edited])
        #expect(LibrarySearchController.matches(query: "replacement", notes: [edited], documents: documents)
            == [edited.libraryIdentity])
        #expect(LibrarySearchController.matches(query: "original", notes: [edited], documents: documents).isEmpty)
    }

    @Test
    func twoFilesWithOneUUIDKeepSeparateCachedDocumentsAndSearchResults() async {
        let sharedID = UUID()
        let first = note(
            title: "Research", summary: "Orchid project",
            id: sharedID, fileURL: URL(fileURLWithPath: "/synthetic/library/first.md")
        )
        let second = note(
            title: "Research", summary: "Granite project",
            id: sharedID, fileURL: URL(fileURLWithPath: "/synthetic/library/second.md")
        )
        #expect(first.fileModified == second.fileModified)
        let cache = SearchDocumentCache()
        let documents = await cache.documents(for: [first, second])

        #expect(documents.count == 2)
        #expect(LibrarySearchController.matches(query: "orchid", notes: [first, second], documents: documents)
            == [first.libraryIdentity])
        #expect(LibrarySearchController.matches(query: "granite", notes: [first, second], documents: documents)
            == [second.libraryIdentity])
        #expect(LibrarySearchController.matches(query: "research", notes: [first, second], documents: documents)
            == [first.libraryIdentity, second.libraryIdentity])
    }

    @Test
    func switchingLibrariesCannotReuseACopiedUUIDsPreviousSearchDocument() async {
        let sharedID = UUID()
        let first = note(
            title: "Planning", summary: "Harbour work",
            id: sharedID, fileURL: URL(fileURLWithPath: "/synthetic/first-library/meeting.md")
        )
        let copied = note(
            title: "Planning", summary: "Mountain work",
            id: sharedID, fileURL: URL(fileURLWithPath: "/synthetic/copied-library/meeting.md")
        )
        let cache = SearchDocumentCache()
        _ = await cache.documents(for: [first])
        let copiedDocuments = await cache.documents(for: [copied])
        #expect(copiedDocuments.count == 1)
        #expect(copiedDocuments[first.libraryIdentity] == nil)
        #expect(LibrarySearchController.matches(query: "mountain", notes: [copied], documents: copiedDocuments)
            == [copied.libraryIdentity])
        #expect(LibrarySearchController.matches(query: "harbour", notes: [copied], documents: copiedDocuments).isEmpty)

        let originalDocuments = await cache.documents(for: [first])
        #expect(LibrarySearchController.matches(query: "harbour", notes: [first], documents: originalDocuments)
            == [first.libraryIdentity])
    }

    @Test
    func aRevisionlessModelNeverUsesAnOlderSavedFilesCachedWords() async {
        let cache = SearchDocumentCache()
        let saved = note(title: "Research", summary: "Archived wording")
        _ = await cache.documents(for: [saved])
        var transient = saved
        transient.fileRevision = nil
        transient.summary = "First live wording"
        let first = await cache.documents(for: [transient])
        #expect(first[transient.libraryIdentity]?.contains("first live wording") == true)
        #expect(first[transient.libraryIdentity]?.contains("archived wording") == false)

        transient.summary = "Second live wording"
        let second = await cache.documents(for: [transient])
        #expect(second[transient.libraryIdentity]?.contains("second live wording") == true)
        #expect(second[transient.libraryIdentity]?.contains("first live wording") == false)
    }

    @Test
    func anUnsavedModelIsRebuiltEvenIfItRetainsAnEarlierRevision() async {
        let cache = SearchDocumentCache()
        var transient = note(title: "Draft", summary: "Earlier thought", fileURL: nil)
        transient.fileRevision = Data(repeating: 7, count: 32)
        _ = await cache.documents(for: [transient])
        transient.summary = "Newest thought"
        let documents = await cache.documents(for: [transient])

        #expect(documents[transient.libraryIdentity]?.contains("newest thought") == true)
        #expect(documents[transient.libraryIdentity]?.contains("earlier thought") == false)
    }

    @Test
    func matchesWithoutACacheStillReturnsTheExactFileIdentity() {
        let target = note(title: "Roadmap", summary: "Ship v2 behind a flag")
        let other = note(
            title: "Retro", summary: "Nothing related", id: target.id,
            fileURL: URL(fileURLWithPath: "/synthetic/library/other.md")
        )
        let identities = LibrarySearchController.matches(query: "roadmap flag", notes: [target, other])
        #expect(identities == [target.libraryIdentity])
    }

    @Test
    func removingANoteRemovesItsDocumentFromTheCurrentSearchSnapshot() async {
        let cache = SearchDocumentCache()
        let stays = note(title: "Stays", summary: "Kept note")
        let goes = note(
            title: "Goes", summary: "Removed note",
            fileURL: URL(fileURLWithPath: "/synthetic/library/removed.md")
        )
        _ = await cache.documents(for: [stays, goes])
        let current = await cache.documents(for: [stays])

        #expect(current.count == 1)
        #expect(current[stays.libraryIdentity] != nil)
        #expect(current[goes.libraryIdentity] == nil)
    }

    @Test
    @MainActor
    func aNewQuerySupersedesAPendingSearchWithoutPublishingTheOldMatches() async throws {
        let first = note(title: "Orchid", summary: "First search result")
        let second = note(
            title: "Granite", summary: "Second search result",
            fileURL: URL(fileURLWithPath: "/synthetic/library/second.md")
        )
        let controller = LibrarySearchController()
        controller.update(query: "orchid", notes: [first, second])
        controller.update(query: "granite", notes: [first, second])
        try await waitForSearch(controller)

        #expect(controller.matchingIDs == [second.libraryIdentity])
    }

    @Test
    @MainActor
    func clearingTheQueryCancelsAPendingSearchAndRestoresAnUnfilteredLibrary() async throws {
        let note = note(title: "Pending", summary: "Some searchable words")
        let controller = LibrarySearchController()
        controller.update(query: "searchable", notes: [note])
        controller.update(query: "  \n", notes: [note])
        try await Task.sleep(for: .milliseconds(240))

        #expect(controller.matchingIDs == nil)
        #expect(!controller.isSearching)
    }

    @Test
    func literalCandidatesMustStillRespectWholeCharacterBoundariesAndLaterMatches() {
        for (document, term) in [
            ("cafe\u{301}", "cafe"),
            ("go\u{301}", "go"),
            ("1️⃣", "1"),
            ("\u{0600}a", "a"),
            ("ss\u{200D}", "ss"),
        ] {
            #expect(!LibrarySearchTerm(term).matches(in: document))
            #expect(LibrarySearchTerm(term).matches(in: document + " later " + term))
        }
    }

    @Test
    func nonASCIIAndPunctuationKeepCanonicalCharacterSearch() {
        for (document, term) in [
            ("cafe\u{301}", "café"),
            ("café", "cafe\u{301}"),
            ("각", "각"),
            ("K", "K"),
            ("\u{037E}", ";"),
            ("\u{1FEF}", "`"),
            ("👨‍👩‍👧‍👦\u{00AD}🇺🇳cafe\u{301}ıss\u{200D}神\u{FEFF}", "ss\u{200D}"),
        ] {
            #expect(document.contains(term))
            #expect(LibrarySearchTerm(term).matches(in: document))
        }
        #expect(!LibrarySearchTerm("cafe").matches(in: "café"))
        #expect(!LibrarySearchTerm("👩").matches(in: "👩🏽‍💻"))
        #expect(!LibrarySearchTerm("🇦").matches(in: "🇦🇺"))
        #expect(!LibrarySearchTerm("\r").matches(in: "\r\n"))
    }

    @Test
    func optimizedTermsAgreeWithTheOriginalMatcherAcrossMixedUnicode() {
        let atoms = [
            "", "a", "word", "ss", "1", "12", "redaction", "café", "cafe\u{301}",
            "\u{301}", "a\u{308}\u{301}", "a\u{301}\u{308}", "👩🏽‍💻", "👩", "🏽", "💻",
            "\u{200D}", "🇦🇺", "🇦", "🇺", "🇦🇺🇳", "🇺🇳", "\r\n", "\r", "\n",
            "क्‍ष", "क", "ष", "K", "K", "k", "Å", "Å", "A\u{30A}", "ﬀ", "ff",
            "ß", "ss", "İ", "i", "ı", "i\u{307}", "Σ", "σ", "ς", "1️⃣", "\u{FE0F}",
            "\0", "a\0b", "각", "각", "ᄀ", "가", "word\u{301}", "\u{0600}a",
            "神", "神", "❤︎", "❤️", "\u{200B}", "\u{2060}", "\u{FEFF}", "\u{00AD}",
            "\u{037E}", ";", "\u{1FEF}", "`", "ب\u{0651}\u{064E}", "ب\u{064E}\u{0651}",
        ]
        var mismatches: [String] = []
        func compare(_ document: String, _ term: String) {
            // This is the previous production operation, independent of the
            // candidate search and its boundary checks.
            if LibrarySearchTerm(term).matches(in: document) != document.contains(term) {
                mismatches.append("\(document.debugDescription) / \(term.debugDescription)")
            }
        }
        for atom in atoms {
            for document in [atom, "prefix " + atom + " suffix", atom + atom,
                             atom.precomposedStringWithCanonicalMapping,
                             atom.decomposedStringWithCanonicalMapping] {
                for term in atoms { compare(document, term) }
            }
        }
        var seed: UInt64 = 0x1234_5678
        func random(_ limit: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 32) % UInt64(limit))
        }
        for _ in 0..<512 {
            let source = (0..<(random(10) + 1)).map { _ in atoms[random(atoms.count)] }.joined()
            let scalars = Array(source.unicodeScalars)
            let start = random(scalars.count + 1)
            let end = start + random(scalars.count - start + 1)
            let term = String(String.UnicodeScalarView(scalars[start..<end]))
            compare(source, term)
            compare(source.precomposedStringWithCanonicalMapping, term.decomposedStringWithCanonicalMapping)
            for asciiTerm in ["word", "ss", "i", "1"] {
                compare(source, asciiTerm)
                compare(source + " " + asciiTerm, asciiTerm)
            }
        }
        #expect(mismatches.isEmpty)
    }

    @Test
    func cachedAndFreshSearchKeepCaseWhitespaceSubstringAndFieldCoverage() async {
        let phrases = ["Café ROADMAP", "cafe\u{301} roadmap", "İSTANBUL", "Σ σ ς", "각 각", "word\u{301} later word", "ss\u{200D}", "Alpha12" ]
        var notes: [MeetingNote] = []
        let sharedID = UUID()
        for (index, phrase) in phrases.enumerated() {
            var value = note(
                title: "Title \(phrase)", summary: "Summary \(phrase)", id: sharedID,
                fileURL: URL(fileURLWithPath: "/synthetic/differential/note-\(index).md")
            )
            value.sourceApp = "Provider \(index)"
            value.keyPoints = ["Keypoint\(index)"]
            value.decisions = ["Decision\(index)"]
            value.actionItems = ["Action\(index)"]
            value.personalNotes = "Personal\(index)"
            value.transcript = [TranscriptSegment(startTime: 0, duration: 1, text: "Transcript\(index)", source: .microphone)]
            value.fileRevision = MeetingNote.contentRevision(Data(MarkdownCodec.encode(value).utf8))
            notes.append(value)
        }
        let documents = await SearchDocumentCache().documents(for: notes)
        for query in ["", " \t\n", "CAFÉ", "cafe\u{301}", "cafe", "  ROAD\tTITLE\n", "sum", "İ", "i", "Σ", "각", "word", "ss\u{200D}", "alpha12", "12", "keypoint2", "decision3", "action4", "personal5", "transcript6", "provider\u{00A0}7", "missingword"] {
            let terms = query.split(whereSeparator: \.isWhitespace).map { String($0).localizedLowercase }
            let expected = Set(notes.compactMap { value -> LibraryNoteIdentity? in
                let originalDocument = [value.title, value.summary, value.sourceApp,
                                        value.keyPoints.joined(separator: " "), value.decisions.joined(separator: " "),
                                        value.actionItems.joined(separator: " "), value.personalNotes,
                                        value.transcriptText].joined(separator: "\n").localizedLowercase
                return terms.allSatisfy(originalDocument.contains) ? value.libraryIdentity : nil
            })
            #expect(LibrarySearchController.matches(query: query, notes: notes) == expected)
            #expect(LibrarySearchController.matches(query: query, notes: notes, documents: documents) == expected)
        }
    }

    @Test
    func cancelledWorkSkipsDocumentBuildingAndMatching() async {
        let value = note(title: "Target", summary: "Matching wording")
        let cache = SearchDocumentCache()
        let gate = AsyncStream<Void>.makeStream()
        let worker = Task.detached {
            for await _ in gate.stream { break }
            let documents = await cache.documents(for: [value])
            let matches = LibrarySearchController.matches(query: "matching", notes: [value])
            return (documents, matches)
        }
        worker.cancel()
        gate.continuation.finish()
        let (cancelledDocuments, cancelledMatches) = await worker.value
        #expect(cancelledDocuments.isEmpty)
        #expect(cancelledMatches.isEmpty)
        let nextDocuments = await cache.documents(for: [value])
        #expect(LibrarySearchController.matches(query: "matching", notes: [value], documents: nextDocuments) == [value.libraryIdentity])
    }

    @Test
    @MainActor
    func repeatedEmptyQueriesKeepTheLibraryUnfilteredWithoutPublishing() {
        let value = note(title: "Target", summary: "Matching wording")
        let controller = LibrarySearchController { _, _, _ in
            Issue.record("An empty query must not start matching.")
            return []
        }
        var publications = 0
        let observation = controller.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }

        controller.update(query: "", notes: [value])
        controller.update(query: " \t\n", notes: [])

        #expect(controller.matchingIDs == nil)
        #expect(!controller.isSearching)
        #expect(publications == 0)
    }

    @Test
    @MainActor
    func clearingAQueryCancelsItsRunningMatcherBeforeQuietEmptyRefreshes() async throws {
        let value = note(title: "Target", summary: "Matching wording")
        let cancellation = SearchCancellationObservation()
        let controller = LibrarySearchController { _, _, _ in
            await cancellation.started()
            try? await Task.sleep(for: .seconds(2))
            await cancellation.finished(wasCancelled: Task.isCancelled)
            return [value.libraryIdentity]
        }
        controller.update(query: "matching", notes: [value])
        for _ in 0..<100 {
            if await cancellation.didStart { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await cancellation.didStart)
        controller.update(query: " \n", notes: [value])
        #expect(controller.matchingIDs == nil)
        #expect(!controller.isSearching)
        var publications = 0
        let observation = controller.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        controller.update(query: "", notes: [])
        for _ in 0..<100 {
            if await cancellation.wasCancelled { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(await cancellation.wasCancelled)
        #expect(controller.matchingIDs == nil)
        #expect(!controller.isSearching)
        #expect(publications == 0)
    }

    @Test
    @MainActor
    func replacingAQueryCancelsAnAlreadyRunningDetachedMatcher() async throws {
        let value = note(title: "Target", summary: "Matching wording")
        let observation = SearchCancellationObservation()
        let controller = LibrarySearchController { query, _, _ in
            if query == "first" {
                await observation.started()
                try? await Task.sleep(for: .seconds(2))
                await observation.finished(wasCancelled: Task.isCancelled)
                return [value.libraryIdentity]
            }
            return []
        }
        controller.update(query: "first", notes: [value])
        for _ in 0..<100 {
            if await observation.didStart { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let didStart = await observation.didStart
        #expect(didStart)
        controller.update(query: "second", notes: [value])
        try await waitForSearch(controller)
        let wasCancelled = await observation.wasCancelled
        #expect(wasCancelled)
        #expect(controller.matchingIDs == [])
    }

    @Test
    @MainActor
    func releasingASearchControllerCancelsItsActiveMatcher() async throws {
        let value = note(title: "Target", summary: "Matching wording")
        let observation = SearchCancellationObservation()
        var controller: LibrarySearchController? = LibrarySearchController { _, _, _ in
            await observation.started()
            try? await Task.sleep(for: .seconds(2))
            await observation.finished(wasCancelled: Task.isCancelled)
            return [value.libraryIdentity]
        }
        let controllerWasReleased = { [weak controller] in controller == nil }
        controller?.update(query: "matching", notes: [value])
        for _ in 0..<100 {
            if await observation.didStart { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let didStart = await observation.didStart
        #expect(didStart)
        controller = nil
        #expect(controllerWasReleased())
        for _ in 0..<100 {
            if await observation.wasCancelled { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let wasCancelled = await observation.wasCancelled
        #expect(wasCancelled)
    }

    @MainActor
    private func waitForSearch(_ controller: LibrarySearchController) async throws {
        for _ in 0..<100 where controller.isSearching {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!controller.isSearching)
    }
}

private actor SearchCancellationObservation {
    private(set) var didStart = false
    private(set) var wasCancelled = false
    func started() { didStart = true }
    func finished(wasCancelled: Bool) { self.wasCancelled = wasCancelled }
}
