import Foundation
import Testing
@testable import Nook

/// Every boundary is synthetic: no EKEventStore, system permission prompt,
/// Reminders database or UserDefaults domain is constructed by this suite.
@MainActor
struct ReminderExportTests {
    @Test(arguments: [false, true])
    func overlappingExportsOfTheSameActionSaveOnlyOnce(acrossControllers: Bool) async throws {
        let fixture = try ReminderExportFixture()
        defer { fixture.cleanup() }
        let first = fixture.controller()
        let second = acrossControllers ? fixture.controller() : first
        let entry = try #require(fixture.entries.first)
        let original = try fixture.bytes()
        let task = fixture.start(entry, controller: first)
        await fixture.client.waitForRequests(1)

        await second.sendToReminders(entry, library: fixture.snapshot)

        #expect(fixture.client.factories == 1)
        #expect(fixture.client.saveAttempts == 0)
        #expect(second.lastError?.contains("already being sent") == true)
        fixture.client.finish(0, with: .success(true))
        await task.value
        #expect(fixture.client.saved.count == 1)
        #expect(first.exportedIDs.contains(entry.id))
        #expect(first.lastError == nil)
        #expect(fixture.receipts.keys == [fixture.key(for: entry)])
        #expect(try fixture.bytes() == original)

        await second.sendToReminders(entry, library: fixture.snapshot)
        #expect(second.exportedIDs.contains(entry.id))
        #expect(fixture.client.factories == 1)
        #expect(fixture.client.saved.count == 1)
    }

    @Test
    func differentActionsCanFinishOutOfOrderWithoutLosingOtherReceipts() async throws {
        let fixture = try ReminderExportFixture(actions: ["Send the agenda", "Book the room"])
        defer { fixture.cleanup() }
        let firstEntry = fixture.entries[0]
        let secondEntry = fixture.entries[1]
        let first = fixture.start(firstEntry, controller: fixture.controller())
        await fixture.client.waitForRequests(1)
        let second = fixture.start(secondEntry, controller: fixture.controller())
        await fixture.client.waitForRequests(2)

        fixture.client.finish(1, with: .success(true))
        await second.value
        #expect(fixture.receipts.keys == [fixture.key(for: secondEntry)])
        fixture.receipts.keys.insert("existing receipt from another writer")
        fixture.client.finish(0, with: .success(true))
        await first.value

        #expect(fixture.client.saved.map(\.title) == ["Book the room", "Send the agenda"])
        #expect(fixture.receipts.keys == [
            fixture.key(for: firstEntry), fixture.key(for: secondEntry),
            "existing receipt from another writer"
        ])
        // A recreated coordinator models loading persisted receipts on the
        // next launch, independently of the old coordinator's reservations.
        let recreated = fixture.controller(state: fixture.makeState())
        await recreated.sendToReminders(firstEntry, library: fixture.snapshot)
        await recreated.sendToReminders(secondEntry, library: fixture.snapshot)
        #expect(fixture.client.factories == 2)
        #expect(recreated.exportedIDs == [firstEntry.id, secondEntry.id])
    }

    @Test
    func anUnrelatedSuccessfulExportDoesNotHideAnotherActionsFailure() async throws {
        let fixture = try ReminderExportFixture(actions: ["Send the agenda", "Book the room"])
        defer { fixture.cleanup() }
        let controller = fixture.controller()
        let firstEntry = fixture.entries[0]
        let secondEntry = fixture.entries[1]
        let first = fixture.start(firstEntry, controller: controller)
        await fixture.client.waitForRequests(1)
        let second = fixture.start(secondEntry, controller: controller)
        await fixture.client.waitForRequests(2)
        fixture.client.finish(0, with: .success(false))
        await first.value
        #expect(controller.lastError?.contains("declined") == true)

        fixture.client.finish(1, with: .success(true))
        await second.value
        #expect(controller.lastError?.contains("declined") == true)
        #expect(fixture.receipts.keys == [fixture.key(for: secondEntry)])
        let retry = fixture.start(firstEntry, controller: controller)
        await fixture.client.waitForRequests(3)
        fixture.client.finish(2, with: .success(true))
        await retry.value
        #expect(controller.lastError == nil)
        #expect(fixture.client.saved.count == 2)
    }

    @Test
    func legacyReceiptStillRecognizesAnActionAfterLineAndDueDateChanges() async throws {
        let fixture = try ReminderExportFixture(actions: ["Send the agenda [due: 2026-09-12]"])
        defer { fixture.cleanup() }
        let original = try #require(fixture.entries.first)
        // This is the exact pre-fix persistence format, without a path/index.
        fixture.receipts.keys.insert("\(original.noteID.uuidString)|Send the agenda")
        try fixture.replaceActions(["New item above", "Send the agenda [due: 2026-09-19]"])
        let moved = fixture.entries[1]
        let controller = fixture.controller()

        await controller.sendToReminders(moved, library: fixture.snapshot)

        #expect(moved.itemIndex != original.itemIndex)
        #expect(moved.dueDate != original.dueDate)
        #expect(controller.exportedIDs.contains(moved.id))
        #expect(controller.lastError == "Already in Reminders.")
        #expect(fixture.client.factories == 0)
        #expect(fixture.client.saved.isEmpty)
    }

    @Test
    func aReceiptPersistedDuringPermissionPreventsThePendingSave() async throws {
        let fixture = try ReminderExportFixture()
        defer { fixture.cleanup() }
        let controller = fixture.controller()
        let entry = try #require(fixture.entries.first)
        let task = fixture.start(entry, controller: controller)
        await fixture.client.waitForRequests(1)
        fixture.receipts.keys.insert(fixture.key(for: entry))

        fixture.client.finish(0, with: .success(true))
        await task.value

        #expect(fixture.client.saveAttempts == 0)
        #expect(controller.exportedIDs.contains(entry.id))
        #expect(controller.lastError == "Already in Reminders.")
    }

    @Test(arguments: ["denied", "permissionError", "saveError"])
    func anUnsuccessfulExportReleasesItsReservationForRetry(failure: String) async throws {
        let fixture = try ReminderExportFixture()
        defer { fixture.cleanup() }
        let controller = fixture.controller()
        let entry = try #require(fixture.entries.first)
        let task = fixture.start(entry, controller: controller)
        await fixture.client.waitForRequests(1)
        fixture.client.failSave = failure == "saveError"
        fixture.client.finish(0, with: failure == "permissionError"
            ? .failure(CocoaError(.fileWriteNoPermission))
            : .success(failure != "denied"))
        await task.value

        #expect(fixture.receipts.keys.isEmpty)
        #expect(fixture.client.saved.isEmpty)
        #expect(controller.lastError != nil)
        #expect(!controller.exportedIDs.contains(entry.id))
        fixture.client.failSave = false
        let retry = fixture.start(entry, controller: controller)
        await fixture.client.waitForRequests(2)
        fixture.client.finish(1, with: .success(true))
        await retry.value

        #expect(fixture.client.saved.count == 1)
        #expect(fixture.receipts.keys == [fixture.key(for: entry)])
        #expect(controller.exportedIDs.contains(entry.id))
        #expect(controller.lastError == nil)
    }

    @Test
    func cancellationAllowsRetryBeforeANoncooperatingPermissionRequestReturns() async throws {
        let fixture = try ReminderExportFixture()
        defer { fixture.cleanup() }
        let controller = fixture.controller()
        let entry = try #require(fixture.entries.first)
        let cancelled = fixture.start(entry, controller: controller)
        await fixture.client.waitForRequests(1)
        cancelled.cancel()
        let retry = fixture.start(entry, controller: controller)
        await fixture.client.waitForRequests(2)

        // The old system callback resumes late and says permission was
        // granted. It cannot save or release the newer request's reservation.
        fixture.client.finish(0, with: .success(true))
        await cancelled.value
        #expect(fixture.client.saveAttempts == 0)
        let otherWindow = fixture.controller()
        await otherWindow.sendToReminders(entry, library: fixture.snapshot)
        #expect(fixture.client.factories == 2)
        #expect(otherWindow.lastError?.contains("already being sent") == true)
        fixture.client.finish(1, with: .success(true))
        await retry.value

        #expect(fixture.client.saved.count == 1)
        #expect(controller.lastError == nil)
        #expect(fixture.receipts.keys == [fixture.key(for: entry)])
    }

    @Test
    func anAlreadyCancelledRequestDoesNotConstructAClientAndDoesNotBlockRetry() async throws {
        let fixture = try ReminderExportFixture()
        defer { fixture.cleanup() }
        let controller = fixture.controller()
        let entry = try #require(fixture.entries.first)
        let task = fixture.start(entry, controller: controller)
        task.cancel()
        await task.value

        #expect(fixture.client.factories == 0)
        #expect(fixture.receipts.keys.isEmpty)
        let retry = fixture.start(entry, controller: controller)
        await fixture.client.waitForRequests(1)
        fixture.client.finish(0, with: .success(true))
        await retry.value
        #expect(fixture.client.saved.count == 1)
    }

    @Test(arguments: [false, true], [false, true])
    func exportPreservesTheExactTitleAndTheDueMorningWithoutEditingTheNote(hasDueDate: Bool, isSpoken: Bool) async throws {
        let text = "Send Cafe\u{301} notes" + (hasDueDate ? " [due: 2026-09-12]" : "")
        let fixture = try ReminderExportFixture(actions: [text], kind: isSpoken ? .spoken : .meeting)
        defer { fixture.cleanup() }
        let entry = try #require(fixture.entries.first)
        let original = try fixture.bytes()
        let task = fixture.start(entry, controller: fixture.controller())
        await fixture.client.waitForRequests(1)
        fixture.client.finish(0, with: .success(true))
        await task.value

        let payload = try #require(fixture.client.saved.first)
        #expect(payload.title.utf8.elementsEqual("Send Cafe\u{301} notes".utf8))
        if hasDueDate {
            let due = try #require(payload.dueDateComponents)
            #expect(due.year == 2026)
            #expect(due.month == 9)
            #expect(due.day == 12)
            #expect(due.hour == 9)
            #expect(due.calendar == fixture.calendar)
        } else {
            #expect(payload.dueDateComponents == nil)
        }
        #expect(try fixture.bytes() == original)
    }

    @Test(arguments: ["externalEdit", "unicodeEdit", "completed", "missing", "duplicate", "folder", "folderBack", "loading"])
    func aChangedSourceOrLibraryDuringPermissionNeverReachesReminders(change: String) async throws {
        let fixture = try ReminderExportFixture(actions: ["Send Cafe\u{301} notes"])
        defer { fixture.cleanup() }
        let entry = try #require(fixture.entries.first)
        let controller = fixture.controller()
        let task = fixture.start(entry, controller: controller)
        await fixture.client.waitForRequests(1)
        try fixture.changeSource(change)
        let remainingFiles = try fixture.allFileBytes()

        fixture.client.finish(0, with: .success(true))
        await task.value

        #expect(fixture.client.saveAttempts == 0)
        #expect(fixture.receipts.keys.isEmpty)
        #expect(controller.lastError != nil)
        #expect(!controller.exportedIDs.contains(entry.id))
        #expect(try fixture.allFileBytes() == remainingFiles)
    }

    @Test
    func aByteDifferentActionCannotBorrowACanonicallyEquivalentRowsAuthority() async throws {
        let fixture = try ReminderExportFixture(actions: ["Send Cafe\u{301} notes"])
        defer { fixture.cleanup() }
        fixture.client.gated = false
        let entry = try #require(fixture.entries.first)
        let altered = OpenAction(
            noteID: entry.noteID, itemIndex: entry.itemIndex,
            text: "Send Caf\u{e9} notes", dueDate: entry.dueDate,
            noteTitle: entry.noteTitle, startedAt: entry.startedAt,
            sourceFileURL: entry.sourceFileURL, sourceRevision: entry.sourceRevision
        )
        #expect(altered.text == entry.text)
        #expect(!altered.text.utf8.elementsEqual(entry.text.utf8))
        let controller = fixture.controller()

        await controller.sendToReminders(altered, library: fixture.snapshot)

        #expect(fixture.client.factories == 0)
        #expect(fixture.client.saved.isEmpty)
        #expect(controller.lastError?.contains("changed") == true)
    }

    @Test
    func aFolderRoundTripBeforeTheScheduledTaskBeginsCannotExportTheOldAction() async throws {
        let fixture = try ReminderExportFixture()
        defer { fixture.cleanup() }
        fixture.client.gated = false
        let entry = try #require(fixture.entries.first)
        let oldGeneration = fixture.generation
        fixture.generation += 2
        let controller = fixture.controller()

        await controller.sendToReminders(
            entry, expectedGeneration: oldGeneration, library: fixture.snapshot
        )

        #expect(fixture.client.factories == 0)
        #expect(fixture.client.saved.isEmpty)
        #expect(controller.lastError?.contains("folder changed") == true)
    }

    @Test(arguments: ["externalEdit", "completed", "missing", "duplicate", "folder", "loading"])
    func anAlreadyStaleActionIsRefusedWithoutRequestingPermission(change: String) async throws {
        let fixture = try ReminderExportFixture(actions: ["Send Cafe\u{301} notes"])
        defer { fixture.cleanup() }
        fixture.client.gated = false
        let entry = try #require(fixture.entries.first)
        try fixture.changeSource(change)
        let controller = fixture.controller()

        await controller.sendToReminders(entry, library: fixture.snapshot)

        #expect(fixture.client.factories == 0)
        #expect(fixture.client.saved.isEmpty)
        #expect(fixture.receipts.keys.isEmpty)
        #expect(controller.lastError != nil)
    }
}

@MainActor
private final class ReminderExportFixture {
    let root: URL
    let originalDirectory: URL
    var directory: URL
    let noteURL: URL
    var generation = 0
    var isLoading = false
    var notes: [MeetingNote] = []
    let receipts = ReminderExportReceipts()
    let client = ControlledReminderClient()
    let calendar: Calendar
    lazy var state = makeState()

    init(actions: [String] = ["Send the agenda"], kind: NoteKind = .meeting) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NookReminderExport-\(UUID().uuidString)", isDirectory: true)
        originalDirectory = root.appendingPathComponent("Notes", isDirectory: true)
        directory = originalDirectory
        noteURL = originalDirectory.appendingPathComponent("Synthetic-meeting.md")
        var selectedCalendar = Calendar(identifier: .gregorian)
        selectedCalendar.timeZone = .current
        calendar = selectedCalendar
        try FileManager.default.createDirectory(at: originalDirectory, withIntermediateDirectories: true)
        let note = MeetingNote(
            kind: kind,
            title: "Synthetic follow-up", startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            endedAt: Date(timeIntervalSince1970: 1_780_000_060), sourceApp: "Personal",
            summary: kind == .spoken ? actions.map { "- [ ] \($0)" }.joined(separator: "\n")
                : "Synthetic reminder export acceptance.",
            actionItems: kind == .spoken ? [] : actions
        )
        try write(note)
    }

    var entries: [OpenAction] {
        guard let note = notes.first, let markdown = try? String(contentsOf: noteURL, encoding: .utf8) else { return [] }
        let items = note.kind == .spoken ? MarkdownCodec.spokenCheckboxLines(in: markdown)
            : MarkdownCodec.actionItemLines(in: markdown)
        return items.filter { !$0.isChecked }.map { item in
            OpenAction(
                noteID: note.id, itemIndex: item.index, text: item.text, dueDate: item.dueDate,
                noteTitle: note.title, startedAt: note.startedAt,
                sourceFileURL: noteURL, sourceRevision: note.fileRevision
            )
        }
    }

    func snapshot() -> ReminderExportLibrarySnapshot {
        .init(directoryURL: directory, generation: generation, isLoading: isLoading, notes: notes)
    }

    func makeState() -> ReminderExportState {
        let receipts = self.receipts
        return ReminderExportState(load: { receipts.keys }, persist: { receipts.keys = $0 })
    }

    func controller(state: ReminderExportState? = nil) -> OpenActionsController {
        let client = self.client
        return OpenActionsController(
            reminderExports: state ?? self.state,
            makeReminderClient: { client.make() }, reminderCalendar: calendar
        )
    }

    func start(_ entry: OpenAction, controller: OpenActionsController) -> Task<Void, Never> {
        let expectedGeneration = generation
        return Task { @MainActor in
            await controller.sendToReminders(
                entry, expectedGeneration: expectedGeneration, library: self.snapshot
            )
        }
    }

    func key(for entry: OpenAction) -> String { "\(entry.noteID.uuidString)|\(entry.displayText)" }
    func bytes() throws -> Data { try Data(contentsOf: noteURL) }
    func cleanup() { client.finishAll(); try? FileManager.default.removeItem(at: root) }

    func write(_ note: MeetingNote) throws {
        let markdown = MarkdownCodec.encode(note)
        let bytes = Data(markdown.utf8)
        try bytes.write(to: noteURL)
        var decoded = try #require(MarkdownCodec.decode(markdown, fileURL: noteURL))
        decoded.fileRevision = MeetingNote.contentRevision(bytes)
        notes = [decoded]
    }

    func replaceActions(_ actions: [String]) throws {
        var note = try #require(notes.first)
        note.actionItems = actions
        try write(note)
    }

    func changeSource(_ change: String) throws {
        switch change {
        case "externalEdit":
            let old = try String(contentsOf: noteURL, encoding: .utf8)
            try Data(old.replacingOccurrences(of: "Send Cafe\u{301} notes", with: "Different action").utf8).write(to: noteURL)
        case "unicodeEdit":
            try replaceActions(["Send Caf\u{e9} notes"])
        case "completed":
            var note = try #require(notes.first)
            note.completedActionItems = Set(note.actionItems)
            try write(note)
        case "missing":
            try FileManager.default.removeItem(at: noteURL)
        case "duplicate":
            let copy = originalDirectory.appendingPathComponent("Copy.md")
            try FileManager.default.copyItem(at: noteURL, to: copy)
            var copied = try #require(notes.first)
            copied.fileURL = copy
            notes.append(copied)
        case "folder", "folderBack":
            directory = root.appendingPathComponent("Other", isDirectory: true)
            generation += 1
            if change == "folderBack" { directory = originalDirectory; generation += 1 }
            // Deliberately retain the old models, as a failed reload can.
        case "loading":
            isLoading = true
        default:
            Issue.record("Unknown synthetic source change")
        }
    }

    func allFileBytes() throws -> [URL: Data] {
        let files = try FileManager.default.contentsOfDirectory(
            at: originalDirectory, includingPropertiesForKeys: nil
        )
        return try Dictionary(uniqueKeysWithValues: files.map { ($0, try Data(contentsOf: $0)) })
    }
}

@MainActor
private final class ReminderExportReceipts { var keys: Set<String> = [] }

@MainActor
private final class ControlledReminderClient {
    var factories = 0
    var saveAttempts = 0
    var saved: [ReminderExportPayload] = []
    var failSave = false
    var gated = true
    private var requests: [CheckedContinuation<Bool, Error>?] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func make() -> ReminderExportClient {
        factories += 1
        return ReminderExportClient(
            requestAccess: { try await self.request() },
            save: { payload in
                self.saveAttempts += 1
                if self.failSave { throw CocoaError(.fileWriteNoPermission) }
                self.saved.append(payload)
            }
        )
    }

    func request() async throws -> Bool {
        if !gated { return true }
        return try await withCheckedThrowingContinuation { continuation in
            requests.append(continuation)
            let ready = waiters.filter { $0.0 <= requests.count }
            waiters.removeAll { $0.0 <= requests.count }
            ready.forEach { $0.1.resume() }
        }
    }

    func waitForRequests(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func finish(_ index: Int, with result: Result<Bool, Error>) {
        let continuation = requests[index]
        requests[index] = nil
        continuation?.resume(with: result)
    }

    func finishAll() {
        for index in requests.indices { finish(index, with: .success(false)) }
        waiters.forEach { $0.1.resume() }
        waiters.removeAll()
    }
}
