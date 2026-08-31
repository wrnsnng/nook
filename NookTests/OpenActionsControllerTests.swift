import AppKit
import Combine
import Foundation
import SwiftUI
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
        let store = MarkdownStore(noteLoader: { _, cache in
            MarkdownStore.loadNotes(in: directory, cache: cache)
        })
        store.storageURL = directory
        store.reload()
        for _ in 0..<100 where store.isLoading {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return store
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NookActionIdentity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func reload(_ store: MarkdownStore) async {
        store.reload()
        for _ in 0..<200 where store.isLoading {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(!store.isLoading)
    }

    private func change(_ action: String, entry: OpenAction, controller: OpenActionsController, store: MarkdownStore) async {
        if action == "toggle" {
            await controller.toggle(entry, store: store)
        } else {
            await controller.setDue(entry, on: Date(timeIntervalSince1970: 1_900_000_000), store: store)
        }
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
        var publications = 0
        let observation = controller.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }

        // Nothing on disk changed, so the cached read should report the
        // same single open action rather than losing or duplicating it.
        await controller.refresh(store: store)
        #expect(controller.entries.count == 1)
        #expect(controller.entries.first?.displayText == "Draft the migration note")
        #expect(publications == 0)
    }

    @Test
    func unchangedActionWordingStillPublishesItsNewExactFileRevision() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try writeNote(in: directory, actionItems: "- [ ] Review the recap")
        let initial = try String(contentsOf: file, encoding: .utf8)
            .replacingOccurrences(of: "Talked it through.", with: "Café recap.")
        try Data(initial.utf8).write(to: file)
        let store = await makeStore(in: directory)
        let controller = OpenActionsController()
        await controller.refresh(store: store)
        let original = try #require(controller.entries.first)
        var publishedEntries: [[OpenAction]] = []
        let observation = controller.$entries.dropFirst().sink { publishedEntries.append($0) }
        defer { observation.cancel() }

        let replacement = initial.replacingOccurrences(of: "Café", with: "Cafe\u{301}")
        #expect(initial == replacement)
        #expect(!initial.utf8.elementsEqual(replacement.utf8))
        try Data(replacement.utf8).write(to: file)
        await reload(store)
        await controller.refresh(store: store)

        let revised = try #require(controller.entries.first)
        #expect(publishedEntries == [[revised]])
        #expect(revised.id == original.id)
        #expect(revised.text.utf8.elementsEqual(original.text.utf8))
        #expect(revised.sourceRevision != original.sourceRevision)
        #expect(revised.sourceRevision == MeetingNote.contentRevision(Data(replacement.utf8)))
        await controller.toggle(original, store: store)
        #expect(try Data(contentsOf: file) == Data(replacement.utf8))
        await controller.toggle(revised, store: store)
        await controller.refresh(store: store)
        #expect(controller.entries.isEmpty)
        #expect(controller.lastError == nil)
    }

    @Test
    func unchangedActionsStillRefreshReminderReceiptsFromAnotherWindow() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try writeNote(in: directory, actionItems: "- [ ] Send the recap")
        let store = await makeStore(in: directory)
        var receipts: Set<String> = []
        let state = ReminderExportState(load: { receipts }, persist: { receipts = $0 })
        let controller = OpenActionsController(reminderExports: state)
        await controller.refresh(store: store)
        let original = try #require(controller.entries.first)
        var entryPublications = 0
        var exportedPublications: [Set<String>] = []
        let entriesObservation = controller.$entries.dropFirst().sink { _ in entryPublications += 1 }
        let exportedObservation = controller.$exportedIDs.dropFirst().sink { exportedPublications.append($0) }
        defer {
            entriesObservation.cancel()
            exportedObservation.cancel()
        }

        receipts.insert("\(original.noteID.uuidString)|\(original.displayText)")
        await controller.refresh(store: store)
        #expect(controller.entries == [original])
        #expect(controller.exportedIDs == [original.id])
        await controller.refresh(store: store)
        #expect(exportedPublications == [[original.id]])
        receipts = []
        await controller.refresh(store: store)

        #expect(entryPublications == 0)
        #expect(exportedPublications == [[original.id], []])
        #expect(controller.exportedIDs.isEmpty)
    }

    @Test
    func quietRefreshPreservesReminderErrorsAndStillReportsAndClearsAmbiguousCopies() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try writeNote(in: directory, actionItems: "- [ ] Review the proposal")
        let store = await makeStore(in: directory)
        let controller = OpenActionsController(
            reminderExports: ReminderExportState(load: { [] }, persist: { _ in }),
            makeReminderClient: {
                ReminderExportClient(requestAccess: { false }, save: { _ in
                    Issue.record("Declined access must not save a reminder.")
                })
            }
        )
        await controller.refresh(store: store)
        let original = try #require(controller.entries.first)
        await controller.sendToReminders(original, store: store)
        let reminderError = try #require(controller.lastError)
        #expect(reminderError.contains("declined"))
        var publications = 0
        let observation = controller.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        await controller.refresh(store: store)
        #expect(controller.lastError == reminderError)
        #expect(publications == 0)

        let copy = directory.appendingPathComponent("Separate copy.md")
        try FileManager.default.copyItem(at: file, to: copy)
        await reload(store)
        await controller.refresh(store: store)
        #expect(controller.entries.isEmpty)
        #expect(controller.lastError?.contains("Review the copies") == true)
        let duplicatePublications = publications
        #expect(duplicatePublications > 0)
        await controller.refresh(store: store)
        #expect(publications == duplicatePublications)

        try FileManager.default.removeItem(at: copy)
        await reload(store)
        await controller.refresh(store: store)
        #expect(controller.entries == [original])
        #expect(controller.lastError == nil)
        #expect(publications > duplicatePublications)
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

    @Test(arguments: ["toggle", "due"])
    func duplicateNoteIDsHideAmbiguousActionsAndRefuseOldRowMutations(action: String) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try writeNote(in: directory, actionItems: "- [ ] First copy action")
        let store = await makeStore(in: directory)
        let controller = OpenActionsController()
        await controller.refresh(store: store)
        let oldEntry = try #require(controller.entries.first)
        let copy = directory.appendingPathComponent("Separate-copy.md")
        let copiedSource = try String(contentsOf: file, encoding: .utf8)
            .replacingOccurrences(of: "First copy action", with: "Different copy action")
        try Data(copiedSource.utf8).write(to: copy)
        await reload(store)
        await controller.refresh(store: store)
        let firstBytes = try Data(contentsOf: file)
        let secondBytes = try Data(contentsOf: copy)

        #expect(controller.entries.isEmpty)
        #expect(controller.lastError?.contains("Review the copies") == true)
        await change(action, entry: oldEntry, controller: controller, store: store)

        #expect(try Data(contentsOf: file) == firstBytes)
        #expect(try Data(contentsOf: copy) == secondBytes)
        #expect(controller.entries.isEmpty)
        #expect(controller.lastError?.contains("Review the copies") == true)
    }

    @Test(arguments: ["toggle", "due"])
    func aSameTimestampEditRefreshesActionsAndAnOldRowCannotEditTheReplacement(action: String) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let file = try writeNote(id: id, in: directory, actionItems: "- [ ] Earlier action")
        // A whole-second value survives Foundation's attribute round trip
        // exactly, unlike a newly created file's subsecond timestamp.
        let modified = Date(timeIntervalSince1970: 1_750_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        let store = await makeStore(in: directory)
        let controller = OpenActionsController()
        await controller.refresh(store: store)
        let oldEntry = try #require(controller.entries.first)
        #expect(store.notes.first?.fileModified == modified)
        _ = try writeNote(id: id, in: directory, actionItems: "- [ ] Externally replaced action")
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        await reload(store)
        await controller.refresh(store: store)
        let changedBytes = try Data(contentsOf: file)

        #expect(store.notes.first?.fileModified == modified)
        #expect(controller.entries.first?.text == "Externally replaced action")
        await change(action, entry: oldEntry, controller: controller, store: store)

        #expect(try Data(contentsOf: file) == changedBytes)
        #expect(controller.entries.first?.text == "Externally replaced action")
        #expect(controller.lastError?.contains("changed or moved") == true)
    }

    @Test(arguments: ["toggle", "due"])
    func anExternalReplacementBeforeReloadCannotBeEditedThroughAnOldAction(action: String) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let file = try writeNote(id: id, in: directory, actionItems: "- [ ] Earlier action")
        let store = await makeStore(in: directory)
        let controller = OpenActionsController()
        await controller.refresh(store: store)
        let entry = try #require(controller.entries.first)
        _ = try writeNote(id: id, in: directory, actionItems: "- [ ] Different action at the same line")
        let replacementBytes = try Data(contentsOf: file)

        await change(action, entry: entry, controller: controller, store: store)

        #expect(try Data(contentsOf: file) == replacementBytes)
        #expect(controller.lastError?.contains("changed or moved") == true)
    }

    @Test(arguments: ["toggle", "due"])
    func switchingToACopiedLibraryCannotRedirectAnOldAction(action: String) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstLibrary = root.appendingPathComponent("Original", isDirectory: true)
        let secondLibrary = root.appendingPathComponent("Copied", isDirectory: true)
        try FileManager.default.createDirectory(at: firstLibrary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondLibrary, withIntermediateDirectories: true)
        let file = try writeNote(in: firstLibrary, actionItems: "- [ ] Identical copied action")
        let copy = secondLibrary.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: copy)
        let store = MarkdownStore(noteLoader: { directory, cache in
            if directory == firstLibrary || directory == secondLibrary {
                return MarkdownStore.loadNotes(in: directory, cache: cache)
            }
            return .success((notes: [], issues: []))
        })
        store.storageURL = firstLibrary
        await reload(store)
        let controller = OpenActionsController()
        await controller.refresh(store: store)
        let oldEntry = try #require(controller.entries.first)
        store.storageURL = secondLibrary
        await reload(store)
        await controller.refresh(store: store)
        let copiedEntry = try #require(controller.entries.first)
        let originalBytes = try Data(contentsOf: file)

        #expect(oldEntry.noteID == copiedEntry.noteID)
        #expect(oldEntry.sourceRevision == copiedEntry.sourceRevision)
        #expect(oldEntry.id != copiedEntry.id)
        await change(action, entry: oldEntry, controller: controller, store: store)

        #expect(try Data(contentsOf: file) == originalBytes)
        #expect(try Data(contentsOf: copy) == originalBytes)
        #expect(controller.lastError?.contains("changed or moved") == true)
    }

    @Test
    func aMountedPaletteHostReceivesChangedAndRemovedActionsFromRealFileRefreshes() async throws {
        let directory = try temporaryDirectory()
        let defaultsName = "NookPaletteActionHost-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: directory)
        }
        let noteID = UUID()
        let file = try writeNote(
            id: noteID, in: directory, actionItems: "- [ ] Original synthetic action"
        )
        let store = await makeStore(in: directory)
        let controller = OpenActionsController()
        // Keep the palette's other observable inputs fixed. A store reload
        // must not accidentally stand in for observing the actions controller.
        let initialNotes = store.notes
        let paletteStore = MarkdownStore(noteLoader: { _, _ in
            .success((notes: initialNotes, issues: []))
        })
        paletteStore.storageURL = directory
        await reload(paletteStore)
        let meeting = MeetingCoordinator(store: paletteStore, detector: MeetingDetector())
        let shortcuts = ShortcutStore(defaults: defaults)
        let observation = PaletteActionHostObservation()
        let root = CommandPaletteOpenActionsHost(openActions: controller) { entries in
            // Record the real host's delivered value without publishing any
            // test state back into SwiftUI or replacing the hosted root view.
            observation.latestEntries = entries
            return CommandPaletteView(
                isPresented: .constant(true),
                openActionEntries: entries,
                createNote: { _ in }, createWeeklyDigest: {},
                showAskSheet: {}, presentQuickNote: {},
                onSelectCommand: { _ in
                    observation.selectedCommands += 1
                    return .dismiss
                }
            )
        }
        .environmentObject(paletteStore)
        .environmentObject(meeting)
        .environmentObject(shortcuts)
        let hostingView = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 464),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        defer {
            window.contentView = nil
            window.close()
        }

        try await waitForPaletteHost(hostingView, observation: observation, entries: [])
        await controller.refresh(store: store)
        let original = try #require(controller.entries.first)
        #expect(controller.entries.count == 1)
        try await waitForPaletteHost(hostingView, observation: observation, entries: [original])
        #expect(observation.latestEntries?.first?.displayText == "Original synthetic action")

        _ = try writeNote(
            id: noteID, in: directory, actionItems: "- [ ] Revised synthetic action"
        )
        await reload(store)
        await controller.refresh(store: store)
        let revised = try #require(controller.entries.first)
        #expect(revised.id == original.id)
        #expect(revised.sourceRevision != original.sourceRevision)
        try await waitForPaletteHost(hostingView, observation: observation, entries: [revised])
        #expect(observation.latestEntries?.first?.displayText == "Revised synthetic action")

        let sevenActions = (1...7).map { "- [ ] Synthetic action \($0)" }.joined(separator: "\n")
        _ = try writeNote(id: noteID, in: directory, actionItems: sevenActions)
        await reload(store)
        await controller.refresh(store: store)
        #expect(controller.entries.count == 7)
        try await waitForPaletteHost(
            hostingView, observation: observation, entries: Array(controller.entries.prefix(6))
        )
        #expect(observation.latestEntries?.count == 6)

        _ = try writeNote(
            id: noteID, in: directory,
            actionItems: sevenActions.replacingOccurrences(of: "- [ ]", with: "- [x]")
        )
        let completedBytes = try Data(contentsOf: file)
        await reload(store)
        await controller.refresh(store: store)
        #expect(controller.entries.isEmpty)
        try await waitForPaletteHost(hostingView, observation: observation, entries: [])

        #expect(window.contentView === hostingView)
        #expect(!window.isVisible)
        #expect(observation.selectedCommands == 0)
        #expect(meeting.phase == .idle)
        #expect(try Data(contentsOf: file) == completedBytes)
    }

    private func waitForPaletteHost(
        _ hostingView: NSView,
        observation: PaletteActionHostObservation,
        entries: [OpenAction]
    ) async throws {
        // Let SwiftUI process its observed publication. Do not assign a new
        // root view or force invalidation, which would hide a broken bridge.
        for _ in 0..<200 {
            hostingView.layoutSubtreeIfNeeded()
            if observation.latestEntries == entries { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(observation.latestEntries == entries)
    }
}

@MainActor
private final class PaletteActionHostObservation {
    var latestEntries: [OpenAction]?
    var selectedCommands = 0
}
