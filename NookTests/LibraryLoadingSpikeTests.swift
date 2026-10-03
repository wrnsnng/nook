import Foundation
import Testing
@testable import Nook

struct LibraryLoadingSpikeTests {
    private func note(_ title: String = "Synthetic café") -> MeetingNote {
        MeetingNote(title: title, startedAt: Date(timeIntervalSince1970: 1_780_000_000),
                    endedAt: Date(timeIntervalSince1970: 1_780_000_060), sourceApp: "Synthetic",
                    summary: "A summary", personalNotes: "Private annotation",
                    transcript: [.init(startTime: 0, duration: 12, text: "Unopened cobalt evidence", source: .system)])
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Nook-Loading-Spike-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test(arguments: [NoteKind.meeting, .spoken, .digest])
    func metadataAgreesWithFullDecodeIncludingEscapesAndSessionDuration(kind: NoteKind) throws {
        var original = note("Quotes \" and slash \\ and e\u{301} 🪴")
        original.kind = kind
        original.sessions = [.init(startedAt: original.startedAt, endedAt: original.endedAt),
                             .init(startedAt: original.startedAt, endedAt: original.endedAt)]
        let text = MarkdownCodec.encode(original)
        let full = try #require(MarkdownCodec.decode(text))
        let metadata = try #require(MarkdownCodec.decodeMetadata(text))
        #expect(metadata.id == full.id)
        #expect(metadata.title.utf8.elementsEqual(full.title.utf8))
        #expect(metadata.kind == full.kind)
        #expect(metadata.startedAt == full.startedAt)
        #expect(metadata.endedAt == full.endedAt)
        #expect(metadata.sourceApp == full.sourceApp)
        #expect(metadata.duration == full.duration)
    }

    @Test(arguments: ["heading", "absent", "empty", "duplicate", "invalid", "crlf", "unknownKind"])
    func legacyAndMalformedMetadataHasTheSameMeaningAsFullDecode(variant: String) {
        var text = MarkdownCodec.encode(note())
        switch variant {
        case "heading": text = text.replacingOccurrences(of: "title: \"Synthetic café\"\n", with: "")
        case "absent": text = text.replacingOccurrences(of: "title: \"Synthetic café\"\n", with: "").replacingOccurrences(of: "# Synthetic café", with: "No heading")
        case "empty": text = text.replacingOccurrences(of: "title: \"Synthetic café\"", with: "title: \"\"")
        case "duplicate": text = text.replacingOccurrences(of: "title: \"Synthetic café\"", with: "title: First\ntitle: Last")
        case "invalid": text = text.replacingOccurrences(of: "started:", with: "missing:")
        case "crlf": text = text.replacingOccurrences(of: "\n", with: "\r\n")
        default: text = text.replacingOccurrences(of: "kind: meeting", with: "kind: future")
        }
        let full = MarkdownCodec.decode(text)
        let metadata = MarkdownCodec.decodeMetadata(text)
        #expect(metadata?.id == full?.id)
        #expect(metadata?.title == full?.title)
        #expect(metadata?.kind == full?.kind)
        #expect(metadata?.duration == full?.duration)
    }

    @Test
    func copiedIdentitiesAndUnopenedTranscriptMatchesSurviveFolderDiscovery() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var first = note()
        try MarkdownCodec.encode(first).write(to: root.appendingPathComponent("first.md"), atomically: true, encoding: .utf8)
        first.transcript = [.init(startTime: 0, duration: 12, text: "Unopened orchid evidence", source: .microphone)]
        try MarkdownCodec.encode(first).write(to: folder.appendingPathComponent("copy.md"), atomically: true, encoding: .utf8)
        var cache = LibraryLoadingSpike.Cache()
        let catalog = try LibraryLoadingSpike.scan(root, cache: &cache)
        let full = try MarkdownStore.loadNotes(in: root).get()
        #expect(catalog.issues.isEmpty)
        #expect(catalog.entries.count == 2)
        #expect(Set(catalog.entries.map(\.identity)).count == 2)
        #expect(Set(catalog.entries.map { $0.metadata.id }).count == 1)
        var searchCache = LibraryLoadingSpike.SearchCache()
        for query in ["orchid", "cobalt", "Private annotation", "notfound", "café", "cafe\u{301}", "", "orchid evidence"] {
            #expect(try LibraryLoadingSpike.search(query, catalog: catalog, cache: &searchCache)
                    == LibrarySearchController.matches(query: query, notes: full.notes))
        }
        for entry in catalog.entries {
            let loaded = try LibraryLoadingSpike.load(entry)
            #expect(loaded == full.notes.first { $0.libraryIdentity == entry.identity })
        }
    }

    @Test(arguments: [false, true])
    func sameSizeSameTimestampEditsCannotReuseMetadataOrAuthorizeDeferredLoad(bodyOnly: Bool) throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.md")
        let before = MarkdownCodec.encode(note("First"))
        try before.write(to: file, atomically: true, encoding: .utf8)
        let timestamp = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        var cache = LibraryLoadingSpike.Cache()
        let old = try LibraryLoadingSpike.scan(root, cache: &cache)
        var searchCache = LibraryLoadingSpike.SearchCache()
        #expect(try LibraryLoadingSpike.search("cobalt", catalog: old, cache: &searchCache).count == 1)
        let after = bodyOnly
            ? before.replacingOccurrences(of: "cobalt", with: "orchid")
            : before.replacingOccurrences(of: "First", with: "Other")
        #expect(before.utf8.count == after.utf8.count)
        try after.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: file.path)
        #expect(throws: LibraryLoadingSpike.Failure.self) { try LibraryLoadingSpike.load(old.entries[0]) }
        #expect(throws: LibraryLoadingSpike.Failure.self) { try LibraryLoadingSpike.search("cobalt", catalog: old) }
        #expect(throws: LibraryLoadingSpike.Failure.self) {
            try LibraryLoadingSpike.search("cobalt", catalog: old, cache: &searchCache)
        }
        let refreshed = try LibraryLoadingSpike.scan(root, cache: &cache)
        #expect(refreshed.entries[0].metadata.title == (bodyOnly ? "First" : "Other"))
        #expect(refreshed.entries[0].revision != old.entries[0].revision)
        #expect(try LibraryLoadingSpike.search(bodyOnly ? "orchid" : "Other", catalog: refreshed, cache: &searchCache).count == 1)
        #expect(try LibraryLoadingSpike.search(bodyOnly ? "cobalt" : "First", catalog: refreshed, cache: &searchCache).isEmpty)
        #expect(try Data(contentsOf: file) == Data(after.utf8))
    }

    @Test
    func renamedAndDeletedSourcesFailAndRescansPruneTheirOldAddresses() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.md")
        let moved = root.appendingPathComponent("renamed.md")
        try MarkdownCodec.encode(note()).write(to: file, atomically: true, encoding: .utf8)
        var cache = LibraryLoadingSpike.Cache()
        let old = try LibraryLoadingSpike.scan(root, cache: &cache)
        try FileManager.default.moveItem(at: file, to: moved)
        #expect(throws: (any Error).self) { try LibraryLoadingSpike.load(old.entries[0]) }
        let renamed = try LibraryLoadingSpike.scan(root, cache: &cache)
        #expect(renamed.entries[0].identity != old.entries[0].identity)
        #expect(cache.entries.count == 1)
        #expect(cache.entries[file.standardizedFileURL] == nil)
        try FileManager.default.removeItem(at: moved)
        #expect(throws: (any Error).self) { try LibraryLoadingSpike.load(renamed.entries[0]) }
        #expect(try LibraryLoadingSpike.scan(root, cache: &cache).entries.isEmpty)
        #expect(cache.entries.isEmpty)
    }

    @Test
    func malformedFilesAreVisibleFailuresAndCannotProduceACompleteSearch() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0xff, 0xfe]).write(to: root.appendingPathComponent("invalid.md"))
        var cache = LibraryLoadingSpike.Cache()
        let catalog = try LibraryLoadingSpike.scan(root, cache: &cache)
        #expect(catalog.issues.count == 1)
        #expect(catalog.entries.isEmpty)
        #expect(throws: LibraryLoadingSpike.Failure.self) {
            try LibraryLoadingSpike.search("anything", catalog: catalog)
        }
    }

    @Test
    func cancelledDiscoveryAndSearchThrowInsteadOfPublishingEmptyResults() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try MarkdownCodec.encode(note()).write(to: root.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        var cache = LibraryLoadingSpike.Cache()
        let catalog = try LibraryLoadingSpike.scan(root, cache: &cache)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var local = LibraryLoadingSpike.Cache()
            #expect(throws: CancellationError.self) { try LibraryLoadingSpike.scan(root, cache: &local) }
            #expect(throws: CancellationError.self) { try LibraryLoadingSpike.search("cobalt", catalog: catalog) }
            #expect(local.entries.isEmpty)
        }
        await task.value
    }
}
