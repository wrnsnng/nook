import Foundation
import Testing
@testable import Nook

@MainActor
struct AudioPlaybackTests {
    private func temporaryLibrary() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NookPlayback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func note() -> MeetingNote {
        MeetingNote(
            title: "Synthetic design review",
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            endedAt: Date(timeIntervalSince1970: 1_000_600),
            sourceApp: "Manual",
            summary: "Review the prototype."
        )
    }

    @Test
    func savedAndRenamedNotesFindTheirRetainedRecording() throws {
        let directory = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MarkdownStore(noteLoader: { _, _ in
            .success((notes: [], issues: []))
        })
        store.storageURL = directory
        var saved = try store.save(note())
        let audioURL = store.recordingsDirectory()
            .appendingPathComponent("\(saved.id.uuidString).m4a")
        // Lookup must use the real persistence layout. Audio decoding and
        // hardware playback are separate from resolving the correct file.
        try Data().write(to: audioURL)

        #expect(AudioPlaybackController.audioURL(for: saved) == audioURL)

        saved.title = "A different title after review"
        saved = try store.save(saved)
        #expect(AudioPlaybackController.audioURL(for: saved) == audioURL)
    }

    @Test
    func aCopiedNoteDoesNotPlayAudioFromAnotherLibraryOrAnUnrelatedSibling() throws {
        let firstLibrary = try temporaryLibrary()
        let secondLibrary = try temporaryLibrary()
        defer {
            try? FileManager.default.removeItem(at: firstLibrary)
            try? FileManager.default.removeItem(at: secondLibrary)
        }
        var original = note()
        original.fileURL = firstLibrary.appendingPathComponent("review.md")
        let recordings = firstLibrary.appendingPathComponent(".recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try Data().write(to: recordings.appendingPathComponent("\(original.id.uuidString).m4a"))

        var copied = original
        copied.fileURL = secondLibrary.appendingPathComponent("review.md")
        try Data().write(to: secondLibrary.appendingPathComponent("review.m4a"))

        #expect(AudioPlaybackController.audioURL(for: original) != nil)
        #expect(AudioPlaybackController.audioURL(for: copied) == nil)
    }

    @Test
    func passagesBeforeTheRetainedSittingHaveNoPlaybackPosition() {
        var combined = note()
        combined.audioStart = 1_200

        #expect(AudioPlaybackController.audioOffset(for: 12, in: combined) == nil)
        #expect(AudioPlaybackController.audioOffset(for: 1_200, in: combined) == 0)
        #expect(AudioPlaybackController.audioOffset(for: 1_212, in: combined) == 12)
        #expect(AudioPlaybackController.transcriptOffset(for: 12, in: combined) == 1_212)
    }

    @Test
    func ordinaryRecordingsKeepTheirTranscriptClock() {
        let recorded = note()
        #expect(AudioPlaybackController.audioOffset(for: 37, in: recorded) == 37)
        #expect(AudioPlaybackController.transcriptOffset(for: 37, in: recorded) == 37)
        #expect(AudioPlaybackController.audioOffset(for: -.infinity, in: recorded) == nil)
        #expect(AudioPlaybackController.transcriptOffset(for: .nan, in: recorded) == nil)
    }

    @Test
    func anUnreadableRecordingExplainsWhyPlaybackDidNotStart() throws {
        let directory = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let playback = AudioPlaybackController()

        playback.start(url: directory.appendingPathComponent("missing.m4a"), at: 0)

        #expect(!playback.isPlaying)
        #expect(playback.activeOffset == nil)
        #expect(playback.lastError == "Nook couldn’t open the kept recording.")
    }
}
