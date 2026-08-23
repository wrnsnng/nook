import Foundation
import Testing
@testable import Nook

/// The search document cache must reuse a note's searchable document while
/// its file has not changed, and rebuild it the moment `fileModified` moves,
/// so an edited note's new content is actually searchable again. Joining and
/// lowercasing every note's transcript on every keystroke is the expensive
/// part `matches` used to redo unconditionally.
struct LibrarySearchControllerTests {
    private func note(
        title: String,
        summary: String,
        fileModified: Date?
    ) -> MeetingNote {
        MeetingNote(
            title: title,
            startedAt: .now,
            endedAt: .now,
            sourceApp: "Zoom",
            summary: summary,
            fileModified: fileModified
        )
    }

    @Test
    func aDocumentIsReusedWhileFileModifiedIsUnchanged() async {
        let cache = SearchDocumentCache()
        let stamp = Date(timeIntervalSince1970: 1_000_000)
        let original = note(
            title: "Design review",
            summary: "Original text",
            fileModified: stamp
        )

        let first = await cache.documents(for: [original])
        #expect(first[original.id]?.contains("original text") == true)

        // Same id and `fileModified`, but a different in-memory summary, as
        // if something changed the model without the file actually being
        // rewritten. The cached document must still win.
        var unchangedOnDisk = original
        unchangedOnDisk.summary = "Should not appear"
        let second = await cache.documents(for: [unchangedOnDisk])

        #expect(second[original.id]?.contains("original text") == true)
        #expect(second[original.id]?.contains("should not appear") == false)
    }

    @Test
    func aDocumentIsRebuiltWhenFileModifiedChanges() async {
        let cache = SearchDocumentCache()
        var edited = note(
            title: "Design review",
            summary: "Original text",
            fileModified: Date(timeIntervalSince1970: 1_000_000)
        )
        _ = await cache.documents(for: [edited])

        edited.summary = "Revised text"
        edited.fileModified = Date(timeIntervalSince1970: 2_000_000)
        let rebuilt = await cache.documents(for: [edited])

        #expect(rebuilt[edited.id]?.contains("revised text") == true)
        #expect(rebuilt[edited.id]?.contains("original text") == false)
    }

    /// A note no longer present must not keep its entry alive forever.
    @Test
    func aNoteRemovedFromTheLibraryIsDroppedFromTheCache() async {
        let cache = SearchDocumentCache()
        let stays = note(title: "Stays", summary: "Kept note", fileModified: .now)
        let goes = note(title: "Goes", summary: "Removed note", fileModified: .now)

        let first = await cache.documents(for: [stays, goes])
        #expect(first.count == 2)

        let second = await cache.documents(for: [stays])
        #expect(second.count == 1)
        #expect(second[stays.id] != nil)
    }

    @Test
    func matchesFallsBackToBuildingTheDocumentWithoutACache() {
        let target = note(
            title: "Roadmap",
            summary: "Ship v2 behind a flag",
            fileModified: nil
        )
        let other = note(
            title: "Retro",
            summary: "Nothing related",
            fileModified: nil
        )

        let ids = LibrarySearchController.matches(
            query: "roadmap flag",
            notes: [target, other]
        )

        #expect(ids == [target.id])
    }
}
