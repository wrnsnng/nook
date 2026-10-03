import Foundation

/// Test-only executable: no AppModel, UI, capture, providers or user library.
/// The parent owns its temporary directory and kills only this child process.
@main
struct RecoveryProbe {
    @MainActor
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4,
              ["checkpoint", "recover"].contains(args[1]),
              let kind = DraftEditorKind(rawValue: args[3]) else { throw ProbeError.invalidArguments }
        let root = URL(fileURLWithPath: args[2]).resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
        guard root.path.hasPrefix(temporary), root.lastPathComponent.hasPrefix("Nook-Recovery-Process-"),
              try String(contentsOf: root.appendingPathComponent("probe.marker"), encoding: .utf8) == "synthetic-only" else {
            throw ProbeError.invalidArguments
        }
        let library = root.appendingPathComponent(args[1] == "checkpoint" ? "Library" : "Recovered", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        // Set the argument domain before constructing the store, just as the
        // snapshot tool does. Never write the developer's persistent defaults.
        UserDefaults.standard.setVolatileDomain(["storageDirectory": library.path], forName: UserDefaults.argumentDomain)
        let store = MarkdownStore(noteLoader: { _, _ in .success((notes: [], issues: [])) })
        let journal = DraftJournal(directoryURL: root.appendingPathComponent("Drafts"))
        if args[1] == "checkpoint" {
            let original = try store.save(MeetingNote(title: "Synthetic recovery probe", startedAt: Date(timeIntervalSince1970: 1_780_000_000),
                endedAt: Date(timeIntervalSince1970: 1_780_000_060), sourceApp: "Synthetic",
                summary: "Original summary", personalNotes: "Original annotation"))
            let personal = PersonalNotesDraftController(recovery: journal)
            let markdown = MarkdownDraftController(recovery: journal)
            let quick = QuickNoteController(store: store, recovery: journal,
                availableEngines: { [] }, countWords: { _ in 1 }, suggestTask: { _ in nil })
            personal.prepare(for: original, store: store)
            markdown.prepare(for: original, store: store)
            let words = "  Unfinished Cafe\u{301} 日本語 👩🏽‍💻\r\n" + String(repeating: "Synthetic words stay exact.\n", count: 4_000) + "\n  "
            switch kind {
            case .personalNotes: personal.text = words
            case .markdown: markdown.rawMarkdown += "\n## Synthetic unfinished section\n" + words
            case .quickNote: quick.text = words
            }
            await journal.flush()
            let inspected = DraftJournal(directoryURL: journal.directoryURL)
            await inspected.scan()
            guard let checkpoint = inspected.recoveredDrafts.first(where: { $0.kind == kind }) else { throw ProbeError.missingCheckpoint }
            try JSONEncoder().encode(checkpoint).write(to: root.appendingPathComponent("ready.json"), options: .atomic)
            // Keep all actual editor controllers alive until SIGKILL, without
            // running normal Quit/save cleanup. The checkpoint is acknowledged
            // before the parent kills us; final-keystroke survival is not claimed.
            defer { withExtendedLifetime((personal, markdown, quick)) {} }
            while true { try await Task.sleep(for: .seconds(60)) }
        } else {
            await journal.scan()
            let expected = try JSONDecoder().decode(DraftCheckpoint.self, from: Data(contentsOf: root.appendingPathComponent("ready.json")))
            guard let checkpoint = journal.recoveredDrafts.first(where: { $0.id == expected.id }),
                  checkpoint == expected else { throw ProbeError.changedCheckpoint }
            let recovery = DraftRecoveryController(journal: journal, store: store)
            let result = try await recovery.saveAsNewNote(draftID: checkpoint.id, destinationDirectory: library, expectedCheckpoint: checkpoint)
            await journal.scan()
            let receipt = Receipt(path: result.path, remaining: journal.recoveredDrafts.count)
            try JSONEncoder().encode(receipt).write(to: root.appendingPathComponent("result.json"), options: .atomic)
        }
    }

    struct Receipt: Codable { let path: String; let remaining: Int }
    enum ProbeError: Error { case invalidArguments, missingCheckpoint, changedCheckpoint }
}
