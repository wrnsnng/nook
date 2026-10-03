import Foundation
import Synchronization
import Testing
@testable import Nook

@MainActor
struct LibraryDiscoveryTests {
    private func fixture() throws -> (URL, MeetingNote) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Nook-Discovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let note = MeetingNote(title: "Synthetic", startedAt: Date(timeIntervalSince1970: 1_780_000_000),
                               endedAt: Date(timeIntervalSince1970: 1_780_000_060), sourceApp: "Synthetic",
                               summary: "Saved summary", personalNotes: "Private annotation",
                               transcript: [.init(startTime: 0, duration: 10, text: "Unopened cobalt", source: .system)])
        try MarkdownCodec.encode(note).write(to: root.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        return (root, note)
    }

    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @Test
    func earlyDiscoveryNeverPublishesIncompleteEditableNotes() async throws {
        let (root, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let store = MarkdownStore(directoryURL: root, noteLoader: { directory, cache in
            _ = release.wait(timeout: .now() + 5)
            return MarkdownStore.loadNotes(in: directory, cache: cache)
        }, discoveryLoader: LibraryDiscovery.scan)
        try await settle { store.discovery?.entries.count == 1 }
        #expect(store.isLoading)
        #expect(store.notes.isEmpty)
        let entry = try #require(store.discovery?.entries.first)
        let preview = try LibraryDiscovery.load(entry)
        #expect(preview.personalNotes == original.personalNotes)
        #expect(preview.transcriptText.contains("Unopened cobalt"))
        #expect(store.notes.isEmpty)
        release.signal()
        try await settle { !store.isLoading }
        #expect(store.notes.count == 1)
        #expect(store.notes[0].libraryIdentity == entry.identity)
        #expect(store.notes[0].personalNotes == original.personalNotes)
        #expect(store.discovery == nil)
        #expect(LibrarySearchController.matches(query: "cobalt", notes: store.notes) == [entry.identity])
    }

    @Test(arguments: [false, true])
    func changingFoldersRejectsLateDiscoveryEvenWhenReturningToTheSamePath(returnToOriginal: Bool) async throws {
        let (root, _) = try fixture()
        let (other, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: other) }
        let release = DispatchSemaphore(value: 0)
        let started = Mutex(false)
        defer { release.signal() }
        let store = MarkdownStore(directoryURL: root, noteLoader: MarkdownStore.loadNotes, discoveryLoader: { directory in
            started.withLock { $0 = true }
            let catalog = try LibraryDiscovery.scan(directory)
            _ = release.wait(timeout: .now() + 5)
            return catalog
        })
        try await settle { started.withLock { $0 } }
        store.storageURL = other
        if returnToOriginal { store.storageURL = root }
        release.signal()
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.discovery == nil)
        #expect(store.notes.isEmpty)
        #expect(!store.isLoading)
    }

    @Test
    func aSaveDuringDiscoveryCannotBeReplacedByItsOlderSnapshot() async throws {
        let (root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let store = MarkdownStore(directoryURL: root, noteLoader: { directory, cache in
            let snapshot = MarkdownStore.loadNotes(in: directory, cache: cache)
            _ = release.wait(timeout: .now() + 5)
            return snapshot
        }, discoveryLoader: LibraryDiscovery.scan)
        try await settle { store.discovery != nil }
        var note = try LibraryDiscovery.load(#require(store.discovery?.entries.first))
        note.personalNotes = "Newer user writing"
        let saved = try store.save(note)
        release.signal()
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.notes.first?.personalNotes == "Newer user writing")
        #expect(try store.rawMarkdown(for: saved).contains("Newer user writing"))
        #expect(store.discovery == nil)
        #expect(!store.isLoading)
    }

    @Test
    func readOnlyPreviewRefusesBodyEditsAndMissingSources() throws {
        let (root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try #require(LibraryDiscovery.scan(root).entries.first)
        let before = try String(contentsOf: entry.fileURL, encoding: .utf8)
        let timestamp = try entry.fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        try before.replacingOccurrences(of: "cobalt", with: "orchid").write(to: entry.fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: entry.fileURL.path)
        #expect(throws: LibraryDiscovery.Failure.self) { try LibraryDiscovery.load(entry) }
        try FileManager.default.removeItem(at: entry.fileURL)
        #expect(throws: (any Error).self) { try LibraryDiscovery.load(entry) }
    }

    @Test
    func copiesAndUnreadableFilesRemainDistinctDuringDiscovery() throws {
        let (root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent("note.md"), to: folder.appendingPathComponent("copy.md"))
        try Data([0xff]).write(to: root.appendingPathComponent("corrupt.md"))
        let catalog = try LibraryDiscovery.scan(root)
        #expect(catalog.entries.count == 2)
        #expect(Set(catalog.entries.map(\.identity)).count == 2)
        #expect(Set(catalog.entries.map { $0.metadata.id }).count == 1)
        #expect(catalog.issues.count == 1)
    }
}
