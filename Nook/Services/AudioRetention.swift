import Foundation

/// Optional automatic cleanup of kept meeting audio.
///
/// Off by default: keeping audio is a deliberate choice and Nook never
/// deletes it unasked. When enabled, extracted audio older than the chosen
/// window goes to the Trash on launch, so a mistake is recoverable and the
/// original Markdown note is never touched. Audio without a saved note stays
/// available for recovery until the user explicitly removes it.
enum AudioRetention {
    static let enabledKey = "audioRetentionEnabled"
    static let daysKey = "audioRetentionDays"
    static let defaultDays = 90

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var days: Int {
        let value = UserDefaults.standard.integer(forKey: daysKey)
        return value > 0 ? value : defaultDays
    }

    /// Moves expired audio for completed notes to the Trash. Returns what it
    /// removed, for diagnostics; failures are skipped rather than surfaced
    /// because a locked file must not block the rest of housekeeping.
    @MainActor
    @discardableResult
    static func sweep(
        store: MarkdownStore,
        now: Date = Date(),
        enabled: Bool = AudioRetention.isEnabled,
        retentionDays: Int = AudioRetention.days,
        trashItem: (URL) throws -> Void = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    ) -> [String] {
        guard enabled, retentionDays > 0, !store.isLoading else { return [] }
        let directory = store.recordingsDirectory()
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .contentModificationDateKey, .isRegularFileKey
            ],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let savedNotes = Dictionary(grouping: store.notes, by: \.id)
        // A raw capture beside extracted audio can be an interrupted recovery
        // or a sitting being appended to an existing note. A saved identifier
        // alone cannot prove that this audio has finished serving its purpose.
        let unfinishedIDs = Set(files.compactMap { file -> UUID? in
            guard ["mp4", "sources"].contains(file.pathExtension.lowercased()) else { return nil }
            let stem = file.deletingPathExtension().lastPathComponent
                .components(separatedBy: ".part-").first ?? ""
            return UUID(uuidString: stem)
        })

        var removed: [String] = []
        for file in files where file.pathExtension.lowercased() == "m4a" {
            guard let id = UUID(
                uuidString: file.deletingPathExtension().lastPathComponent
            ), !unfinishedIDs.contains(id),
                  let matchingNotes = savedNotes[id], matchingNotes.count == 1,
                  let values = try? file.resourceValues(forKeys: [
                    .contentModificationDateKey, .isRegularFileKey
                  ]), values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff,
                  stillHasSavedNote(matchingNotes[0], in: store.storageURL)
            else { continue }
            do {
                try trashItem(file)
                removed.append(file.lastPathComponent)
            } catch {
                continue
            }
        }
        return removed
    }

    /// The library can still hold an older snapshot after a folder switch,
    /// deletion in Finder, or an external edit. Cleanup needs a current saved
    /// document, not merely an identifier that happened to be in that snapshot.
    private static func stillHasSavedNote(
        _ note: MeetingNote,
        in directory: URL
    ) -> Bool {
        guard let file = note.fileURL,
              file.deletingLastPathComponent().standardizedFileURL
                == directory.standardizedFileURL,
              let revision = note.fileRevision,
              let contents = try? Data(contentsOf: file)
        else { return false }
        return MeetingNote.contentRevision(contents) == revision
    }
}
