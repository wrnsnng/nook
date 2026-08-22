import Foundation

/// Optional automatic cleanup of kept meeting audio.
///
/// Off by default: keeping audio is a deliberate choice and Nook never
/// deletes it unasked. When enabled, extracted audio older than the chosen
/// window goes to the Trash on launch, so a mistake is recoverable and the
/// original Markdown note is never touched.
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

    /// Moves expired extracted audio to the Trash. Returns what it removed,
    /// for diagnostics; failures are skipped rather than surfaced because a
    /// locked file must not block the rest of housekeeping.
    @MainActor
    @discardableResult
    static func sweep(store: MarkdownStore, now: Date = Date()) -> [String] {
        guard isEnabled else { return [] }
        let directory = store.recordingsDirectory()
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var removed: [String] = []
        for file in files where file.pathExtension.lowercased() == "m4a" {
            let modified = (try? file.resourceValues(forKeys: [
                .contentModificationDateKey
            ]))?.contentModificationDate ?? now
            guard modified < cutoff else { continue }
            do {
                try FileManager.default.trashItem(at: file, resultingItemURL: nil)
                removed.append(file.lastPathComponent)
            } catch {
                continue
            }
        }
        return removed
    }
}
