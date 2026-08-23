import AppKit
import Foundation

struct MarkdownLoadIssue: Identifiable, Hashable, Sendable {
    let fileURL: URL
    let message: String

    var id: URL { fileURL }
}

@MainActor
final class MarkdownStore: ObservableObject {
    typealias LoadPayload = (
        notes: [MeetingNote],
        issues: [MarkdownLoadIssue]
    )
    typealias NoteLoader = @Sendable (
        URL,
        NoteDecodeCache?
    ) -> Result<LoadPayload, Error>

    @Published private(set) var notes: [MeetingNote] = []
    @Published private(set) var loadIssues: [MarkdownLoadIssue] = []
    @Published private(set) var isLoading = false
    @Published var storageURL: URL {
        didSet {
            // Cached decodes belong to the directory they came from.
            decodeCache.clear()
        }
    }
    @Published var lastError: String?

    private let fileManager: FileManager
    private let noteLoader: NoteLoader
    private let decodeCache = NoteDecodeCache()
    private var reloadGeneration = 0

    init(
        fileManager: FileManager = .default,
        noteLoader: @escaping NoteLoader = MarkdownStore.loadNotes
    ) {
        self.fileManager = fileManager
        self.noteLoader = noteLoader
        let configured = UserDefaults.standard.string(forKey: "storageDirectory")
        self.storageURL = configured.map(URL.init(fileURLWithPath:))
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("Nook", isDirectory: true)
        ensureDirectory()
        reload()
    }

    func reload() {
        ensureDirectory()
        reloadGeneration += 1
        let generation = reloadGeneration
        let directory = storageURL
        let noteLoader = noteLoader
        let cache = decodeCache
        isLoading = true

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                noteLoader(directory, cache)
            }.value

            guard generation == reloadGeneration, directory == storageURL else { return }
            // Notes land before the loading flag clears. Observers that wait
            // for the end of loading must never see an empty library that is
            // merely mid-publish.
            switch result {
            case .success(let payload):
                notes = payload.notes
                loadIssues = payload.issues
                lastError = payload.issues.isEmpty
                    ? nil
                    : "\(payload.issues.count) Markdown file\(payload.issues.count == 1 ? "" : "s") couldn’t be loaded."
            case .failure(let error):
                lastError = error.localizedDescription
                loadIssues = []
            }
            isLoading = false
        }
    }

    @discardableResult
    func save(_ note: MeetingNote) throws -> MeetingNote {
        ensureDirectory()
        var saved = note
        let destination = note.fileURL ?? availableDestination(for: note)
        try MarkdownCodec.encode(note).write(to: destination, atomically: true, encoding: .utf8)
        protectSensitiveFile(at: destination)
        saved.fileURL = destination
        invalidateReloadSnapshot()
        upsert(saved)
        lastError = nil
        return saved
    }

    /// Updates personal notes from the freshest in-memory copy and verifies the
    /// Markdown round-trip before the UI reports success.
    @discardableResult
    func updatePersonalNotes(
        _ personalNotes: String,
        for note: MeetingNote
    ) throws -> MeetingNote {
        var updated = notes.first(where: { $0.id == note.id }) ?? note
        updated.personalNotes = personalNotes.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let saved = try save(updated)

        guard
            let destination = saved.fileURL,
            let markdown = try? String(
                contentsOf: destination,
                encoding: .utf8
            ),
            let persisted = MarkdownCodec.decode(
                markdown,
                fileURL: destination
            ),
            persisted.personalNotes == saved.personalNotes
        else {
            throw MarkdownStoreError.writeVerificationFailed
        }
        return saved
    }

    @discardableResult
    func createBlankNote() throws -> MeetingNote {
        try createTemplatedNote(from: .blank)
    }

    /// Creates a note pre-seeded from a template.
    ///
    /// Templates are static text on the model's own fields, so the file that
    /// lands on disk is byte-for-byte what any equivalent note would encode;
    /// nothing is generated and nothing leaves the Mac.
    @discardableResult
    func createTemplatedNote(from template: NoteTemplate) throws -> MeetingNote {
        let now = Date()
        return try save(
            MeetingNote(
                title: template.title,
                startedAt: now,
                endedAt: now,
                sourceApp: "Personal",
                summary: template.summary,
                actionItems: template.actionItems,
                personalNotes: ""
            )
        )
    }

    /// Reads the file as it exists right now, or fails visibly.
    ///
    /// This deliberately does not fall back to an in-memory reconstruction
    /// when the read fails. A fallback handed stale text to the Markdown
    /// source editor, and saving from it replaced whatever was really on disk
    /// with content Nook had merely remembered. Clipboard copies may fall
    /// back; anything that can be saved back must not.
    func rawMarkdown(for note: MeetingNote) throws -> String {
        guard let url = note.fileURL else {
            return MarkdownCodec.encode(note)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func saveRawMarkdown(_ markdown: String, for note: MeetingNote) throws {
        guard let url = note.fileURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard var decoded = MarkdownCodec.decode(markdown, fileURL: url) else {
            throw MarkdownStoreError.invalidDocument
        }
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        protectSensitiveFile(at: url)
        decoded.fileURL = url
        invalidateReloadSnapshot()
        upsert(decoded)
        loadIssues.removeAll { $0.fileURL == url }
        lastError = loadIssues.isEmpty
            ? nil
            : "\(loadIssues.count) Markdown file\(loadIssues.count == 1 ? "" : "s") couldn’t be loaded."
    }

    /// Moves a note's Markdown file to the Trash.
    ///
    /// Trashing rather than unlinking keeps the deletion reversible from the
    /// Finder, which matters for the only destructive action in the library.
    /// Kept audio in the recordings folder is left where it is; the existing
    /// orphan cleanup and audio retention govern it. Returns false and sets
    /// `lastError` when nothing was deleted, leaving every list untouched.
    @discardableResult
    func delete(_ note: MeetingNote) -> Bool {
        guard let url = note.fileURL else {
            // A note that has never been saved has no file to protect.
            notes.removeAll { $0.id == note.id }
            return true
        }
        do {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.trashItem(at: url, resultingItemURL: nil)
            }
        } catch {
            // Volumes without a Trash still deserve a working delete.
            do {
                try fileManager.removeItem(at: url)
            } catch {
                lastError = "Couldn’t move \(url.lastPathComponent) to the Trash: "
                    + error.localizedDescription
                return false
            }
        }
        notes.removeAll { $0.id == note.id }
        invalidateReloadSnapshot()
        lastError = nil
        return true
    }

    func selectStorageDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = storageURL
        panel.prompt = "Choose Folder"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func switchStorageDirectory(to url: URL, copyExistingMarkdown: Bool) throws {
        let oldDirectory = storageURL.standardizedFileURL
        let newDirectory = url.standardizedFileURL
        guard oldDirectory != newDirectory else { return }

        try fileManager.createDirectory(
            at: newDirectory,
            withIntermediateDirectories: true
        )
        if copyExistingMarkdown {
            let sourceFiles = try markdownFiles(in: oldDirectory)
            for source in sourceFiles {
                let destination = availableCopyDestination(
                    named: source.lastPathComponent,
                    in: newDirectory
                )
                try fileManager.copyItem(at: source, to: destination)
            }
        }

        storageURL = newDirectory
        UserDefaults.standard.set(newDirectory.path, forKey: "storageDirectory")
        reload()
    }

    var markdownFileCount: Int {
        (try? markdownFiles(in: storageURL).count) ?? notes.count
    }

    func reveal(_ note: MeetingNote) {
        guard let url = note.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func reveal(_ issue: MarkdownLoadIssue) {
        NSWorkspace.shared.activateFileViewerSelecting([issue.fileURL])
    }

    func openStorageDirectory() {
        NSWorkspace.shared.open(storageURL)
    }

    func recordingsDirectory() -> URL {
        let url = storageURL.appendingPathComponent(".recordings", isDirectory: true)
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            lastError = "Couldn’t prepare the recordings folder: \(error.localizedDescription)"
            return url
        }
        // User-selected non-POSIX volumes may not support this attribute.
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
        return url
    }

    private func protectSensitiveFile(at url: URL) {
        // Some user-selected volumes do not implement POSIX permissions. The
        // note is already saved in that case, so do not turn a successful save
        // into data loss; use the strictest permissions the volume supports.
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func ensureDirectory() {
        do {
            try fileManager.createDirectory(at: storageURL, withIntermediateDirectories: true)
        } catch {
            lastError = "Couldn’t open the notes folder: \(error.localizedDescription)"
        }
    }

    private func upsert(_ note: MeetingNote) {
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index] = note
        } else {
            notes.append(note)
        }
        notes.sort { $0.startedAt > $1.startedAt }
    }

    /// A detached reload is a snapshot of the directory before this mutation.
    /// Advancing the generation prevents that older snapshot from replacing the
    /// note that was just saved, and clears a spinner whose task is now stale.
    private func invalidateReloadSnapshot() {
        reloadGeneration += 1
        isLoading = false
    }

    private func filename(for note: MeetingNote) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let safeTitle = note.title
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let compactTitle = String((safeTitle.isEmpty ? "meeting" : safeTitle).prefix(72))
        return "\(formatter.string(from: note.startedAt))-\(compactTitle).md"
    }

    private func availableDestination(for note: MeetingNote) -> URL {
        let preferred = storageURL.appendingPathComponent(filename(for: note))
        guard fileManager.fileExists(atPath: preferred.path) else {
            return preferred
        }

        if
            let markdown = try? String(contentsOf: preferred, encoding: .utf8),
            MarkdownCodec.decode(markdown)?.id == note.id
        {
            return preferred
        }

        let stem = preferred.deletingPathExtension().lastPathComponent
        let shortID = note.id.uuidString.prefix(8).lowercased()
        let unique = storageURL
            .appendingPathComponent("\(stem)-\(shortID)")
            .appendingPathExtension("md")
        guard fileManager.fileExists(atPath: unique.path) else {
            return unique
        }

        return storageURL
            .appendingPathComponent("\(stem)-\(note.id.uuidString.lowercased())")
            .appendingPathExtension("md")
    }

    private func markdownFiles(in directory: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "md" }
    }

    private func availableCopyDestination(named filename: String, in directory: URL) -> URL {
        let preferred = directory.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: preferred.path) else { return preferred }
        let stem = preferred.deletingPathExtension().lastPathComponent
        let ext = preferred.pathExtension
        var suffix = 2
        while true {
            let candidate = directory
                .appendingPathComponent("\(stem) \(suffix)")
                .appendingPathExtension(ext)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }

    nonisolated static func loadNotes(
        in directory: URL,
        cache: NoteDecodeCache? = nil
    ) -> Result<LoadPayload, Error> {
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension.lowercased() == "md" }
            var notes: [MeetingNote] = []
            var issues: [MarkdownLoadIssue] = []

            for url in urls {
                let modified = try? url.resourceValues(forKeys: [
                    .contentModificationDateKey
                ]).contentModificationDate
                if let modified, let cached = cache?.note(
                    for: url,
                    modified: modified
                ) {
                    notes.append(cached)
                    continue
                }

                do {
                    let markdown = try String(contentsOf: url, encoding: .utf8)
                    guard let note = MarkdownCodec.decode(
                        markdown,
                        fileURL: url
                    ) else {
                        issues.append(
                            MarkdownLoadIssue(
                                fileURL: url,
                                message: "The frontmatter is missing required meeting fields."
                            )
                        )
                        continue
                    }
                    if let modified {
                        cache?.store(note, for: url, modified: modified)
                    }
                    notes.append(note)
                } catch {
                    issues.append(
                        MarkdownLoadIssue(
                            fileURL: url,
                            message: error.localizedDescription
                        )
                    )
                }
            }
            return .success(
                (
                    notes: notes.sorted { $0.startedAt > $1.startedAt },
                    issues: issues.sorted { $0.fileURL.lastPathComponent < $1.fileURL.lastPathComponent }
                )
            )
        } catch {
            return .failure(error)
        }
    }
}

enum MarkdownStoreError: LocalizedError {
    case invalidDocument
    case writeVerificationFailed

    var errorDescription: String? {
        switch self {
        case .invalidDocument:
            "The Markdown frontmatter is missing or invalid. Your changes haven’t been written."
        case .writeVerificationFailed:
            "Nook couldn’t verify the saved note. Your Markdown file was left untouched."
        }
    }
}

/// Starting points for a new note in the library.
///
/// Deliberately tiny: three skeletons whose value is the checklist they save
/// the user from retyping, not content. Every seed line is an ordinary
/// action item the sidebar already understands.
enum NoteTemplate: String, CaseIterable, Identifiable {
    case blank
    case oneOnOne
    case standup
    case interview

    var id: Self { self }

    var title: String {
        switch self {
        case .blank: "Untitled note"
        case .oneOnOne: "1:1"
        case .standup: "Standup"
        case .interview: "Interview"
        }
    }

    /// Menu label; the blank case keeps its existing verb.
    var menuTitle: String {
        switch self {
        case .blank: "Blank note"
        default: title
        }
    }

    var summary: String { "" }

    var actionItems: [String] {
        switch self {
        case .blank: []
        case .oneOnOne: ["Follow up from last time", "Topics to cover"]
        case .standup: ["Yesterday", "Today", "Blockers"]
        case .interview: ["Questions", "Impressions", "Next steps"]
        }
    }
}
