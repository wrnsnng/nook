import Foundation
import Testing
@testable import Nook

struct PrivacyStorageTests {
    @Test
    @MainActor
    func newNotesAndRecordingDirectoryUsePrivatePermissions() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(
                "NookPrivacyStorage-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: directory) }

        let store = MarkdownStore()
        store.storageURL = directory
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let saved = try store.save(
            MeetingNote(
                title: "Privacy review",
                startedAt: timestamp,
                endedAt: timestamp,
                sourceApp: "Manual",
                summary: "Stored locally."
            )
        )
        let noteURL = try #require(saved.fileURL)
        let recordingDirectory = store.recordingsDirectory()

        let noteAttributes = try fileManager.attributesOfItem(
            atPath: noteURL.path
        )
        let directoryAttributes = try fileManager.attributesOfItem(
            atPath: recordingDirectory.path
        )

        #expect(noteAttributes[.posixPermissions] as? Int == 0o600)
        #expect(directoryAttributes[.posixPermissions] as? Int == 0o700)
    }
}
