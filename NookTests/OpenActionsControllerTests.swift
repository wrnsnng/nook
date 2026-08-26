import Foundation
import Testing
@testable import Nook

/// `refresh` used to re-read and re-parse every action-bearing note's file
/// from disk on every `store.notes` publish, twice per toggle. These pin
/// the user-visible behaviour that must survive the caching rework: the
/// same open actions are reported whether or not anything on disk actually
/// changed, and toggling one still updates the list.
@MainActor
struct OpenActionsControllerTests {
    private func writeNote(
        id: UUID = UUID(),
        in directory: URL,
        actionItems: String
    ) throws -> URL {
        let markdown = """
            ---
            id: \(id.uuidString)
            started: 2026-08-20T09:00:00Z
            ended: 2026-08-20T10:00:00Z
            ---

            # Review

            ## Summary

            Talked it through.

            ## Key points

            _None captured._

            ## Decisions

            _None captured._

            ## Action items

            \(actionItems)

            ## My notes

            _No personal notes._
            """
        let url = directory.appendingPathComponent("\(id.uuidString).md")
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeStore(in directory: URL) async -> MarkdownStore {
        let store = MarkdownStore()
        store.storageURL = directory
        store.reload()
        for _ in 0..<100 where store.isLoading {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return store
    }

    @Test
    func refreshingTwiceWithoutAFileChangeReportsTheSameOpenAction() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NookOpenActionsTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try writeNote(
            in: directory,
            actionItems: "- [ ] Draft the migration note"
        )
        let store = await makeStore(in: directory)
        let controller = OpenActionsController()

        await controller.refresh(store: store)
        #expect(controller.entries.count == 1)
        #expect(controller.entries.first?.displayText == "Draft the migration note")

        // Nothing on disk changed, so the cached read should report the
        // same single open action rather than losing or duplicating it.
        await controller.refresh(store: store)
        #expect(controller.entries.count == 1)
        #expect(controller.entries.first?.displayText == "Draft the migration note")
    }

    @Test
    func togglingAnActionRemovesItFromTheOpenList() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NookOpenActionsTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try writeNote(
            in: directory,
            actionItems: "- [ ] Draft the migration note"
        )
        let store = await makeStore(in: directory)
        let controller = OpenActionsController()

        await controller.refresh(store: store)
        let entry = try #require(controller.entries.first)

        await controller.toggle(entry, store: store)
        // `toggle` no longer refreshes itself on success; `store.notes`
        // publishing is what the library view reacts to, so refresh once
        // more here to observe the saved state, the same as the view does.
        await controller.refresh(store: store)

        #expect(controller.entries.isEmpty)
        #expect(controller.lastError == nil)
    }

    /// A note whose file has not changed since the last refresh must not
    /// need to exist on disk to still be reported: this is what proves the
    /// second refresh actually reused the cache rather than re-reading (a
    /// broken cache lookup would silently drop the entry once the file is
    /// gone).
    @Test
    func aNoteDeletedFromDiskAfterCachingStillReportsUntilTheNextRealChange() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NookOpenActionsTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let noteURL = try writeNote(
            in: directory,
            actionItems: "- [ ] Draft the migration note"
        )
        let store = await makeStore(in: directory)
        let controller = OpenActionsController()

        await controller.refresh(store: store)
        #expect(controller.entries.count == 1)

        // Remove the file on disk without telling the store; `store.notes`
        // still reports the same `fileModified`, so the cache should still
        // be considered valid and the action still reported.
        try FileManager.default.removeItem(at: noteURL)
        await controller.refresh(store: store)
        #expect(controller.entries.count == 1)
    }

    @Test
    func templatePromptsStayVisibleWithoutBecomingOpenActions() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NookTemplateOpenActionsTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = await makeStore(in: directory)
        let templateNote = try store.createTemplatedNote(from: .standup)
        let realNote = try store.save(
            MeetingNote(
                title: "Real follow-up",
                startedAt: Date(timeIntervalSince1970: 1_755_678_000),
                endedAt: Date(timeIntervalSince1970: 1_755_678_060),
                sourceApp: "Personal",
                summary: "A user-created action.",
                actionItems: ["Send the recap"]
            )
        )
        let controller = OpenActionsController()

        await controller.refresh(store: store)

        #expect(controller.entries.count == 1)
        #expect(controller.entries.first?.noteID == realNote.id)
        #expect(controller.entries.first?.displayText == "Send the recap")

        let templateURL = try #require(templateNote.fileURL)
        let markdown = try String(contentsOf: templateURL, encoding: .utf8)
        #expect(markdown.contains("- [x] Yesterday"))
        #expect(markdown.contains("- [x] Today"))
        #expect(markdown.contains("- [x] Blockers"))
    }
}
