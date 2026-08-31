import Combine
import Darwin
import Foundation
import Synchronization
import Testing
@testable import Nook

@MainActor
struct DraftJournalTests {
    private let instant = Date(timeIntervalSince1970: 1_700_000_000)

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NookDraftJournal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func checkpoint(
        kind: DraftEditorKind = .personalNotes,
        text: String = "  Unfinished café ☕️\n\n",
        sessionID: UUID = UUID()
    ) -> DraftCheckpoint {
        DraftCheckpoint(
            kind: kind,
            libraryPath: "/synthetic/Original Library",
            originalFilePath: "/synthetic/Original Library/Original.md",
            noteID: UUID(),
            title: "Original title",
            text: text,
            baseline: "Original baseline\n",
            baselineRevision: Data(repeating: 7, count: 32),
            createdAt: instant,
            checkpointedAt: instant,
            sessionID: sessionID,
            completion: DraftCompletion(
                targetPath: "/synthetic/Another Library/Recovered.md",
                noteID: UUID(),
                revision: Data(repeating: 8, count: 32)
            )
        )
    }

    private func fileURL(_ id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func writeFixture(_ data: Data, id: UUID, in directory: URL) throws {
        let url = fileURL(id, in: directory)
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), "The injected filesystem operation should have started.")
    }

    @Test(arguments: DraftEditorKind.allCases, ["", " \n\tCafé 日本語 👩🏽‍💻\r\n"])
    func everyEditorRecoversExactWordsAndOriginalContext(
        kind: DraftEditorKind, text: String
    ) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = UUID()
        let writtenAt = instant.addingTimeInterval(120)
        let journal = DraftJournal(directoryURL: directory, sessionID: session, now: { writtenAt })
        var record = checkpoint(kind: kind, text: text)
        journal.checkpoint(record)
        journal.flushSynchronously()
        record.sessionID = session
        record.checkpointedAt = writtenAt

        let restarted = DraftJournal(directoryURL: directory)
        await restarted.scan()

        #expect(restarted.recoveredDrafts == [record])
        #expect(restarted.issues.isEmpty)
        #expect(restarted.statusMessage == nil)
    }

    @Test
    func liveDraftsNeverBecomeRecoveryCardsInTheirOwnSession() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = DraftJournal(directoryURL: directory)
        journal.checkpoint(checkpoint())
        await journal.flush()
        await journal.scan()
        #expect(journal.recoveredDrafts.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
    }

    @Test
    func completionIntentPreservesRecoveredSessionAndPublishesVerifiedFields() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = instant.addingTimeInterval(60)
        let journal = DraftJournal(directoryURL: directory, now: { date })
        var record = checkpoint()
        try await journal.persistNow(record)
        record.checkpointedAt = date
        #expect(journal.recoveredDrafts == [record])
        #expect(journal.recoveredDrafts.first?.sessionID != journal.sessionID)
    }

    @Test
    func explicitScanDoesNotReturnBeforeInitialRecoveryPublication() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = checkpoint()
        try writeFixture(JSONEncoder().encode(record), id: record.id, in: directory)
        let journal = DraftJournal(directoryURL: directory)
        await journal.scan()
        #expect(journal.recoveredDrafts == [record])
    }

    @Test
    func resolvingAPendingDraftCannotRecreateItDuringFlushOrRestart() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = DraftJournal(directoryURL: directory, idleInterval: 30, maximumInterval: 30)
        let record = checkpoint()
        journal.checkpoint(record)
        journal.resolve(record.id)
        journal.flushSynchronously()
        let restarted = DraftJournal(directoryURL: directory)
        await restarted.scan()
        #expect(restarted.recoveredDrafts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fileURL(record.id, in: directory).path))
    }

    @Test(arguments: [DraftJournalFileOperation.write, .replace])
    func resolutionInvalidatesAWriteAlreadyWaitingAtTheFilesystem(
        blockedOperation: DraftJournalFileOperation
    ) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entered = Mutex(false)
        let gate = DispatchSemaphore(value: 0)
        let journal = DraftJournal(
            directoryURL: directory, idleInterval: 0, maximumInterval: 0,
            beforeFileOperation: { operation, _ in
                if operation == blockedOperation {
                    entered.withLock { $0 = true }
                    _ = gate.wait(timeout: .now() + 2)
                }
            }
        )
        let record = checkpoint()
        journal.checkpoint(record)
        try await waitUntil { entered.withLock { $0 } }
        journal.resolve(record.id)
        gate.signal()
        await journal.flush()
        let restarted = DraftJournal(directoryURL: directory)
        await restarted.scan()
        #expect(restarted.recoveredDrafts.isEmpty)
        #expect(restarted.issues.isEmpty)
    }

    @Test
    func sustainedEditingCheckpointsBeforeTheIdleDelay() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writes = Mutex(0)
        let journal = DraftJournal(
            directoryURL: directory, idleInterval: 60, maximumInterval: 0.03,
            beforeFileOperation: { operation, _ in
                if case .write = operation { writes.withLock { $0 += 1 } }
            }
        )
        var record = checkpoint()
        for index in 0..<12 {
            record.text = "Continuously dictated words \(index)"
            journal.checkpoint(record)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(writes.withLock { $0 } >= 1)
        await journal.flush()
        let restarted = DraftJournal(directoryURL: directory)
        await restarted.scan()
        #expect(restarted.recoveredDrafts.first?.text == record.text)
    }

    @Test
    func oldFailurePublicationCannotReplaceANewerSuccessfulSnapshotDuringRetry() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = Mutex(0)
        let gate = DispatchSemaphore(value: 0)
        let journal = DraftJournal(
            directoryURL: directory, idleInterval: 0, maximumInterval: 0,
            beforeFileOperation: { operation, _ in
                if case .write = operation {
                    let first = calls.withLock { count in count += 1; return count == 1 }
                    if first {
                        _ = gate.wait(timeout: .now() + 2)
                        throw CocoaError(.fileWriteOutOfSpace)
                    }
                }
            }
        )
        var record = checkpoint(text: "Earlier words")
        journal.checkpoint(record)
        try await waitUntil { calls.withLock { $0 } == 1 }
        record.text = "Latest words must win"
        journal.checkpoint(record)
        gate.signal()
        // The synchronous barrier deliberately prevents the first writer's
        // MainActor publication from running until the newer write succeeds.
        journal.flushSynchronously()
        await Task.yield()
        await Task.yield()
        journal.retry()
        await journal.flush()
        let restarted = DraftJournal(directoryURL: directory)
        await restarted.scan()
        #expect(restarted.recoveredDrafts.first?.text == "Latest words must win")
        #expect(journal.statusMessage == nil)
    }

    @Test
    func failedCleanupRetryCannotDeleteNewWritingForTheSameDraft() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fail = Mutex(false)
        let journal = DraftJournal(directoryURL: directory, beforeFileOperation: { operation, _ in
            if case .remove = operation, fail.withLock({ $0 }) {
                throw CocoaError(.fileWriteNoPermission)
            }
        })
        var record = checkpoint(text: "Earlier recovery")
        try await journal.persistNow(record)
        fail.withLock { $0 = true }
        await #expect(throws: (any Error).self) { try await journal.remove(record.id, toTrash: false) }
        #expect(journal.recoveredDrafts.count == 1)
        record.text = "New writing after the cleanup failure"
        journal.checkpoint(record)
        fail.withLock { $0 = false }
        journal.retry()
        await journal.flush()
        let restarted = DraftJournal(directoryURL: directory)
        await restarted.scan()
        #expect(restarted.recoveredDrafts.first?.text == record.text)
    }

    @Test(arguments: [DraftJournalFileOperation.write, .readBack, .replace])
    func aFailedReplacementKeepsThePreviousCompleteFileAndCanRetry(
        operation: DraftJournalFileOperation
    ) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failing = Mutex(false)
        let journal = DraftJournal(directoryURL: directory, beforeFileOperation: { current, _ in
            let shouldFail: Bool
            switch (current, operation) {
            case (.write, .write), (.readBack, .readBack), (.replace, .replace): shouldFail = true
            default: shouldFail = false
            }
            if shouldFail, failing.withLock({ $0 }) { throw CocoaError(.fileWriteOutOfSpace) }
        })
        var record = checkpoint(text: "Last complete checkpoint")
        journal.checkpoint(record)
        await journal.flush()
        let priorBytes = try Data(contentsOf: fileURL(record.id, in: directory))
        record.text = "Newer words still held in memory"
        failing.withLock { $0 = true }
        journal.checkpoint(record)
        await journal.flush()
        #expect(try Data(contentsOf: fileURL(record.id, in: directory)) == priorBytes)
        #expect(journal.statusMessage != nil)
        failing.withLock { $0 = false }
        journal.retry()
        await journal.flush()
        let restarted = DraftJournal(directoryURL: directory)
        await restarted.scan()
        #expect(restarted.recoveredDrafts.first?.text == record.text)
        #expect(journal.statusMessage == nil)
    }

    @Test(arguments: ["text", "baseline"])
    func readbackRejectsChangedUnicodeBytesAndPreservesThePreviousCompleteCopy(field: String) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let alterReadback = Mutex(false)
        let mutationWasCanonicallyEqual = Mutex(false)
        let journal = DraftJournal(directoryURL: directory, beforeFileOperation: { operation, _ in
            guard case .readBack = operation, alterReadback.withLock({ $0 }) else { return }
            let temporary = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "tmp" }
            guard let temporary else { throw CocoaError(.fileNoSuchFile) }
            let expected = try JSONDecoder().decode(DraftCheckpoint.self, from: Data(contentsOf: temporary))
            var changed = expected
            if field == "text" { changed.text = "cafe\u{0301}" }
            else { changed.baseline = "cafe\u{0301}" }
            mutationWasCanonicallyEqual.withLock { $0 = changed == expected }
            try JSONEncoder().encode(changed).write(to: temporary)
        })
        var record = checkpoint(text: "Previous complete words")
        journal.checkpoint(record)
        await journal.flush()
        let file = fileURL(record.id, in: directory)
        let previousBytes = try Data(contentsOf: file)
        record.text = "caf\u{00E9}"
        record.baseline = "caf\u{00E9}"
        alterReadback.withLock { $0 = true }
        journal.checkpoint(record)
        await journal.flush()

        #expect(mutationWasCanonicallyEqual.withLock { $0 })
        #expect(try Data(contentsOf: file) == previousBytes)
        #expect(journal.statusMessage?.contains("could not be verified") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasSuffix(".tmp") })

        alterReadback.withLock { $0 = false }
        journal.retry()
        await journal.flush()
        let restarted = DraftJournal(directoryURL: directory)
        await restarted.scan()
        let recovered = try #require(restarted.recoveredDrafts.first)
        #expect(Data(recovered.text.utf8) == Data(record.text.utf8))
        #expect(Data(recovered.baseline.utf8) == Data(record.baseline.utf8))
        #expect(journal.statusMessage == nil)
    }

    @Test
    func checkpointAndTemporaryFilePermissionsArePrivateBeforeContentIsCommitted() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let observedModes = Mutex<[Int]>([])
        let mainThreadIO = Mutex(false)
        let journal = DraftJournal(directoryURL: directory, beforeFileOperation: { operation, _ in
            if Thread.isMainThread { mainThreadIO.withLock { $0 = true } }
            if case .readBack = operation {
                let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                for url in urls where url.pathExtension == "tmp" {
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    observedModes.withLock { $0.append((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) }
                }
            }
        })
        let record = checkpoint()
        journal.checkpoint(record)
        await journal.flush()
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL(record.id, in: directory).path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(observedModes.withLock { $0 } == [0o600])
        #expect(!mainThreadIO.withLock { $0 })
    }

    @Test
    func symlinkedCheckpointCannotReadOverwriteOrDeleteItsTarget() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("Drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outside = parent.appendingPathComponent("outside.txt")
        let original = Data("Private external content".utf8)
        try original.write(to: outside)
        let record = checkpoint()
        try FileManager.default.createSymbolicLink(at: fileURL(record.id, in: directory), withDestinationURL: outside)
        let journal = DraftJournal(directoryURL: directory)
        await journal.scan()
        #expect(journal.recoveredDrafts.isEmpty)
        #expect(journal.issues.count == 1)
        journal.checkpoint(record)
        await journal.flush()
        await #expect(throws: (any Error).self) { try await journal.remove(record.id, toTrash: false) }
        #expect(try Data(contentsOf: outside) == original)
        #expect(journal.statusMessage != nil)
    }

    @Test
    func symlinkedRecoveryDirectoryIsRejectedWithoutChangingTheDestination() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let target = parent.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let directory = parent.appendingPathComponent("Drafts", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: target)
        let journal = DraftJournal(directoryURL: directory)
        journal.checkpoint(checkpoint())
        await journal.flush()
        await journal.scan()
        #expect(journal.recoveredDrafts.isEmpty)
        #expect(journal.issues.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
    }

    @Test
    func malformedNewerAndNonregularFilesRemainDiscoverableWithoutBlocking() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let badID = UUID()
        let newerID = UUID()
        let pipeID = UUID()
        try writeFixture(Data("not JSON".utf8), id: badID, in: directory)
        try writeFixture(Data("{\"version\":2}".utf8), id: newerID, in: directory)
        #expect(mkfifo(fileURL(pipeID, in: directory).path, 0o600) == 0)
        let journal = DraftJournal(directoryURL: directory)
        await journal.scan()
        #expect(journal.recoveredDrafts.isEmpty)
        #expect(journal.issues.count == 3)
        #expect(journal.issues.contains { $0.fileURL.lastPathComponent == "\(newerID.uuidString).json" && $0.message.contains("different version") })
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 3)
    }

    @Test
    func invalidRevisionAndWrongRecordIdentityAreNotTrusted() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var invalid = checkpoint()
        invalid.baselineRevision = Data([1])
        try writeFixture(JSONEncoder().encode(invalid), id: invalid.id, in: directory)
        let mismatched = checkpoint()
        try writeFixture(JSONEncoder().encode(mismatched), id: UUID(), in: directory)
        let journal = DraftJournal(directoryURL: directory)
        await journal.scan()
        #expect(journal.recoveredDrafts.isEmpty)
        #expect(journal.issues.count == 2)
    }

    @Test
    func oversizedNewTextKeepsTheOldFileAndDoesNotClaimRecoverySucceeded() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = DraftJournal(
            directoryURL: directory,
            limits: DraftJournalLimits(recordBytes: 2_048, scanBytes: 8_192, recordCount: 8)
        )
        var record = checkpoint(text: "Protected words")
        journal.checkpoint(record)
        await journal.flush()
        let previous = try Data(contentsOf: fileURL(record.id, in: directory))
        record.text = "Pending older words"
        journal.checkpoint(record)
        record.text = String(repeating: "a", count: 4_096)
        journal.checkpoint(record)
        await journal.flush()
        #expect(try Data(contentsOf: fileURL(record.id, in: directory)) == previous)
        #expect(journal.statusMessage?.contains("size limit") == true)
    }

    @Test
    func scanLimitsReportUnopenedFilesWithoutEvictingThem() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for _ in 0..<3 {
            let record = checkpoint()
            try writeFixture(JSONEncoder().encode(record), id: record.id, in: directory)
        }
        let journal = DraftJournal(
            directoryURL: directory,
            limits: DraftJournalLimits(recordBytes: 2_048, scanBytes: 8_192, recordCount: 1)
        )
        await journal.scan()
        #expect(journal.recoveredDrafts.count == 1)
        #expect(journal.issues.contains { $0.message.contains("scan limit") })
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 3)
    }

    @Test
    func corruptFilesConsumeTheScanBudgetEvenWhenTheyCannotBeDecoded() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for _ in 0..<3 {
            try writeFixture(Data(repeating: 91, count: 1_500), id: UUID(), in: directory)
        }
        let journal = DraftJournal(
            directoryURL: directory,
            limits: DraftJournalLimits(recordBytes: 2_048, scanBytes: 3_000, recordCount: 8)
        )
        await journal.scan()
        #expect(journal.recoveredDrafts.isEmpty)
        #expect(journal.issues.count == 3)
        #expect(journal.issues.filter { $0.message.contains("scan limit") }.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 3)
    }

    @Test
    func discardUsesTrashAndRetainsRecoveryWhenTrashFails() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failing = Mutex(true)
        let attempts = Mutex<[URL]>([])
        let journal = DraftJournal(directoryURL: directory, trashItem: { url in
            attempts.withLock { $0.append(url) }
            if failing.withLock({ $0 }) { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        })
        let record = checkpoint()
        try await journal.persistNow(record)
        await #expect(throws: (any Error).self) { try await journal.remove(record.id, toTrash: true) }
        #expect(journal.recoveredDrafts.count == 1)
        #expect(FileManager.default.fileExists(atPath: fileURL(record.id, in: directory).path))
        failing.withLock { $0 = false }
        try await journal.remove(record.id, toTrash: true)
        #expect(journal.recoveredDrafts.isEmpty)
        #expect(attempts.withLock { $0 }.count == 2)
    }

    @Test
    func trashRefusesADirectoryReplacedBeforeTheCocoaCall() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("Drafts", isDirectory: true)
        let moved = parent.appendingPathComponent("MovedDrafts", isDirectory: true)
        let unrelated = parent.appendingPathComponent("Unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let record = checkpoint()
        let foreignBytes = Data("Unrelated same-name file".utf8)
        try writeFixture(foreignBytes, id: record.id, in: unrelated)
        let trashCalls = Mutex(0)
        let journal = DraftJournal(directoryURL: directory, beforeFileOperation: { operation, _ in
            if case .remove = operation {
                try FileManager.default.moveItem(at: directory, to: moved)
                try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: unrelated)
            }
        }, trashItem: { url in
            trashCalls.withLock { $0 += 1 }
            try FileManager.default.removeItem(at: url)
        })
        try await journal.persistNow(record)
        await #expect(throws: (any Error).self) { try await journal.remove(record.id, toTrash: true) }
        #expect(trashCalls.withLock { $0 } == 0)
        #expect(try Data(contentsOf: fileURL(record.id, in: unrelated)) == foreignBytes)
        #expect(FileManager.default.fileExists(atPath: fileURL(record.id, in: moved).path))
        #expect(journal.recoveredDrafts.count == 1)
    }

    @Test(arguments: [false, true], [false, true])
    func cleanupRefusesAReplacementOrInPlaceEditBeforeRemovingTheCheckpoint(
        toTrash: Bool, replaceInPlace: Bool
    ) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let replacement = Mutex<Data?>(nil)
        let trashCalls = Mutex(0)
        let journal = DraftJournal(directoryURL: directory, beforeFileOperation: { operation, url in
            guard operation == .remove, let bytes = replacement.withLock({ $0 }) else { return }
            try bytes.write(to: url, options: replaceInPlace ? [] : .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }, trashItem: { url in
            trashCalls.withLock { $0 += 1 }
            try FileManager.default.removeItem(at: url)
        })
        let record = checkpoint(text: "Caf\u{00E9}")
        try await journal.persistNow(record)
        var changed = try #require(journal.recoveredDrafts.first)
        changed.text = "Cafe\u{0301}"
        let changedBytes = try JSONEncoder().encode(changed)
        replacement.withLock { $0 = changedBytes }

        await #expect(throws: (any Error).self) { try await journal.remove(record.id, toTrash: toTrash) }

        #expect(trashCalls.withLock { $0 } == 0)
        #expect(try Data(contentsOf: fileURL(record.id, in: directory)) == changedBytes)
        #expect(journal.recoveredDrafts.count == 1)
        let restarted = DraftJournal(directoryURL: directory)
        await restarted.scan()
        #expect(restarted.recoveredDrafts.first.map { Data($0.text.utf8) } == Data(changed.text.utf8))
    }

    @Test
    func aFailedCleanupRetryKeepsItsOriginalSnapshotAfterARescanFindsNewWriting() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fail = Mutex(false)
        let journal = DraftJournal(directoryURL: directory, beforeFileOperation: { operation, _ in
            if operation == .remove, fail.withLock({ $0 }) { throw POSIXError(.EACCES) }
        })
        let record = checkpoint(text: "The copy originally approved for cleanup")
        try await journal.persistNow(record)
        fail.withLock { $0 = true }
        await #expect(throws: (any Error).self) { try await journal.remove(record.id, toTrash: false) }
        fail.withLock { $0 = false }
        var changed = try #require(journal.recoveredDrafts.first)
        changed.text = "New writing from a different process"
        let bytes = try JSONEncoder().encode(changed)
        try writeFixture(bytes, id: record.id, in: directory)
        await journal.scan()
        #expect(journal.recoveredDrafts.first?.text == changed.text)
        let refused = DeadlineSignal<Bool>()
        let observation = journal.$statusMessage.sink { message in
            if message?.contains("changed before it could be removed") == true { refused.signal(true) }
        }
        defer { observation.cancel() }

        journal.retry()
        let didRefuse = await withDeadline(seconds: 5) { await refused.wait() == true }

        #expect(didRefuse == true)
        #expect(try Data(contentsOf: fileURL(record.id, in: directory)) == bytes)
        #expect(journal.recoveredDrafts.first?.text == changed.text)
    }

    @Test
    func anOrphanedPartialTemporaryFileDoesNotReplaceTheLastCompleteCheckpoint() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = DraftJournal(directoryURL: directory)
        let record = checkpoint(text: "The last complete checkpoint")
        try await journal.persistNow(record)
        let committed = try Data(contentsOf: fileURL(record.id, in: directory))
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let partial = Data("{\"text\":\"A later interrupted write".utf8)
        try partial.write(to: temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)

        let restarted = DraftJournal(directoryURL: directory)
        await restarted.scan()

        #expect(restarted.recoveredDrafts.count == 1)
        #expect(restarted.recoveredDrafts.first?.text == record.text)
        #expect(try Data(contentsOf: fileURL(record.id, in: directory)) == committed)
        #expect(try Data(contentsOf: temporary) == partial)
    }
}
