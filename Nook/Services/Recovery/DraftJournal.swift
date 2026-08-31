import Combine
import Darwin
import Foundation
import Synchronization

enum DraftEditorKind: String, Codable, CaseIterable, Sendable {
    case personalNotes
    case markdown
    case quickNote

    var label: String {
        switch self {
        case .personalNotes: "My notes"
        case .markdown: "Markdown source"
        case .quickNote: "Quick note"
        }
    }
}

/// Written before a recovered note is created. The exact destination and bytes
/// let recovery recognize a completed save after a crash during cleanup.
struct DraftCompletion: Codable, Equatable, Sendable {
    var targetPath: String
    var noteID: UUID
    var revision: Data
}

/// The editor captures this entire value before scheduling a checkpoint. In
/// particular, neither the current library nor a reloaded baseline is consulted
/// by the writer later. An empty replacement is still unfinished writing.
struct DraftCheckpoint: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var kind: DraftEditorKind
    var libraryPath: String
    var originalFilePath: String?
    var noteID: UUID?
    var title: String
    var text: String
    var baseline: String
    var baselineRevision: Data?
    var createdAt: Date
    var checkpointedAt: Date
    var sessionID: UUID
    var version: Int
    var completion: DraftCompletion?

    init(
        id: UUID = UUID(),
        kind: DraftEditorKind,
        libraryPath: String,
        originalFilePath: String? = nil,
        noteID: UUID? = nil,
        title: String,
        text: String,
        baseline: String = "",
        baselineRevision: Data? = nil,
        createdAt: Date = Date(),
        checkpointedAt: Date = Date(),
        sessionID: UUID = UUID(),
        version: Int = 1,
        completion: DraftCompletion? = nil
    ) {
        self.id = id
        self.kind = kind
        self.libraryPath = libraryPath
        self.originalFilePath = originalFilePath
        self.noteID = noteID
        self.title = title
        self.text = text
        self.baseline = baseline
        self.baselineRevision = baselineRevision
        self.createdAt = createdAt
        self.checkpointedAt = checkpointedAt
        self.sessionID = sessionID
        self.version = version
        self.completion = completion
    }

    fileprivate var estimatedBytes: Int {
        text.utf8.count + baseline.utf8.count + title.utf8.count
            + libraryPath.utf8.count + (originalFilePath?.utf8.count ?? 0)
            + (completion?.targetPath.utf8.count ?? 0) + 1_024
    }
}

struct DraftRecoveryIssue: Identifiable, Equatable, Sendable {
    var id: URL { fileURL }
    let fileURL: URL
    let message: String
}

struct DraftJournalLimits: Sendable {
    var recordBytes = 16 * 1_024 * 1_024
    var scanBytes = 64 * 1_024 * 1_024
    var recordCount = 1_024
}

/// Fault injection is deliberately at filesystem boundaries. Tests exercise the
/// preservation of the previous complete file, not a mock journal implementation.
enum DraftJournalFileOperation: Sendable, Equatable {
    case write
    case readBack
    case replace
    case remove
}

/// Owns current-session checkpoints without putting them into live editors or
/// recovery cards. One serial writer keeps filesystem work off the main actor;
/// pending edits coalesce while that writer is busy instead of queuing a copy
/// of a large document for every keystroke.
@MainActor
final class DraftJournal: ObservableObject {
    let directoryURL: URL
    let sessionID: UUID
    @Published private(set) var recoveredDrafts: [DraftCheckpoint] = []
    @Published private(set) var issues: [DraftRecoveryIssue] = []
    @Published private(set) var statusMessage: String?

    private struct Pending {
        var record: DraftCheckpoint
        let firstEdit: Date
        var lastEdit: Date
        let generation: UUID
        let sequence: UInt64
    }

    private struct PendingRemoval: Sendable {
        let toTrash: Bool
        let expected: DraftCheckpoint?
    }

    private let writer: DraftJournalWriter
    private let now: @Sendable () -> Date
    private let idleInterval: TimeInterval
    private let maximumInterval: TimeInterval
    private let limits: DraftJournalLimits
    private var pending: [UUID: Pending] = [:]
    private var failedRecords: [UUID: DraftCheckpoint] = [:]
    private var failedRemovals: [UUID: PendingRemoval] = [:]
    private var failures: [UUID: String] = [:]
    private var generations: [UUID: UUID] = [:]
    private var sequences: [UUID: UInt64] = [:]
    private var nextSequence: UInt64 = 0
    private var timer: Task<Void, Never>?
    private var writeInFlight = false
    private var scanGeneration = 0
    private var hasRequestedScan = false
    private var resolvingIDs: Set<UUID> = []

    init(
        directoryURL: URL? = nil,
        sessionID: UUID = UUID(),
        idleInterval: TimeInterval = 0.4,
        maximumInterval: TimeInterval = 2,
        limits: DraftJournalLimits = DraftJournalLimits(),
        now: @escaping @Sendable () -> Date = { Date() },
        beforeFileOperation: @escaping @Sendable (
            DraftJournalFileOperation, URL
        ) throws -> Void = { _, _ in },
        trashItem: @escaping @Sendable (URL) throws -> Void = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    ) {
        let directory = directoryURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
            .appendingPathComponent(
                Bundle.main.bundleIdentifier ?? "com.localfirst.nook.dev",
                isDirectory: true
            )
            .appendingPathComponent("Drafts", isDirectory: true)
        self.directoryURL = directory.standardizedFileURL
        self.sessionID = sessionID
        self.idleInterval = max(0, idleInterval)
        self.maximumInterval = max(0, maximumInterval)
        self.limits = limits
        self.now = now
        writer = DraftJournalWriter(
            directoryURL: directory.standardizedFileURL,
            limits: limits,
            now: now,
            beforeFileOperation: beforeFileOperation,
            trashItem: trashItem
        )
        Task { [weak self] in
            guard let self, !self.hasRequestedScan else { return }
            await self.scan()
        }
    }

    func checkpoint(_ record: DraftCheckpoint) {
        var record = record
        record.sessionID = sessionID
        if resolvingIDs.remove(record.id) != nil {
            invalidate(record.id)
        }
        let otherBytes = pending.values.filter { $0.record.id != record.id }
            .reduce(0) { $0 + $1.record.estimatedBytes }
            + failedRecords.values.filter { $0.id != record.id }
            .reduce(0) { $0 + $1.estimatedBytes }
        guard record.estimatedBytes <= limits.recordBytes,
              otherBytes + record.estimatedBytes <= limits.scanBytes,
              pending[record.id] != nil || failedRecords[record.id] != nil
                || pending.count + failedRecords.count < limits.recordCount
        else {
            // A rejected newer edit must not let an older pending write clear
            // the failure and imply that the latest words are protected.
            invalidate(record.id)
            failures[record.id] = DraftJournalError.tooLarge.localizedDescription
            refreshStatus()
            return
        }
        let date = now()
        let generation = generation(for: record.id)
        let sequence = sequence(for: record.id)
        pending[record.id] = Pending(
            record: record,
            firstEdit: pending[record.id]?.firstEdit ?? date,
            lastEdit: date,
            generation: generation,
            sequence: sequence
        )
        failedRecords.removeValue(forKey: record.id)
        schedule()
    }

    /// Resolution invalidates both the timer and any writer that has not yet
    /// committed. The queued removal follows a write already in progress, so a
    /// delayed completion cannot recreate a successfully resolved checkpoint.
    func resolve(_ id: UUID) {
        let removal = PendingRemoval(toTrash: false, expected: recoveredDrafts.first { $0.id == id })
        invalidate(id)
        resolvingIDs.insert(id)
        scanGeneration += 1
        let generation = generation(for: id)
        writer.queue.async { [writer, weak self] in
            let result = Result { try writer.remove(id, toTrash: false, expected: removal.expected) }
            Task { @MainActor in
                guard let self, self.generations[id] == generation else { return }
                self.didRemove(id, generation: generation, removal: removal, result: result)
            }
        }
    }

    func flush() async {
        timer?.cancel()
        timer = nil
        let batch = takePending()
        let results = await writer.perform { writer in writer.write(batch) }
        apply(results)
        schedule()
    }

    /// Quit and existing synchronous editor replacement APIs cannot suspend.
    /// The writer never waits for a main-actor callback, so this barrier cannot
    /// deadlock behind publication of an earlier asynchronous write.
    func flushSynchronously() {
        timer?.cancel()
        timer = nil
        let batch = takePending()
        apply(writer.queue.sync { writer.write(batch) })
        schedule()
    }

    /// Unlike a live checkpoint, an intent for an older recovered draft keeps
    /// its original session identity and remains visible until cleanup succeeds.
    func persistNow(_ record: DraftCheckpoint) async throws {
        invalidate(record.id)
        scanGeneration += 1
        let generation = generation(for: record.id)
        let sequence = sequence(for: record.id)
        do {
            let committed = try await writer.perform { writer in
                try writer.write(record, generation: generation)
            }
            guard committed != nil, generations[record.id] == generation,
                  sequences[record.id] == sequence else { throw CancellationError() }
            failures.removeValue(forKey: record.id)
            failedRecords.removeValue(forKey: record.id)
            refreshStatus()
            await scan()
        } catch {
            if generations[record.id] == generation, sequences[record.id] == sequence {
                failedRecords[record.id] = record
                failures[record.id] = error.localizedDescription
                refreshStatus()
            }
            throw error
        }
    }

    func persistSynchronously(_ record: DraftCheckpoint) throws {
        invalidate(record.id)
        scanGeneration += 1
        let generation = generation(for: record.id)
        _ = sequence(for: record.id)
        do {
            let committed = try writer.queue.sync {
                try writer.write(record, generation: generation)
            }
            guard committed != nil else { throw CancellationError() }
            failures.removeValue(forKey: record.id)
            failedRecords.removeValue(forKey: record.id)
            refreshStatus()
        } catch {
            failedRecords[record.id] = record
            failures[record.id] = error.localizedDescription
            refreshStatus()
            throw error
        }
    }

    func remove(_ id: UUID, toTrash: Bool) async throws {
        try await remove(id, removal: PendingRemoval(
            toTrash: toTrash, expected: recoveredDrafts.first { $0.id == id }
        ))
    }

    private func remove(_ id: UUID, removal: PendingRemoval) async throws {
        invalidate(id)
        resolvingIDs.insert(id)
        scanGeneration += 1
        let generation = generation(for: id)
        let result = await writer.perform { writer in
            Result { try writer.remove(id, toTrash: removal.toTrash, expected: removal.expected) }
        }
        didRemove(id, generation: generation, removal: removal, result: result)
        try result.get()
    }

    func scan() async {
        hasRequestedScan = true
        scanGeneration += 1
        let generation = scanGeneration
        let result = await writer.perform { writer in writer.scan() }
        guard generation == scanGeneration else { return }
        recoveredDrafts = result.records.filter { $0.sessionID != sessionID }
            .sorted { $0.checkpointedAt > $1.checkpointedAt }
        issues = result.issues
        refreshStatus()
    }

    func retry() {
        let records = failedRecords.values.sorted { $0.id.uuidString < $1.id.uuidString }
        failedRecords = [:]
        for record in records {
            // A retry must not convert an earlier-session recovery into a live
            // draft or route it through an editor's save/retry machinery.
            let date = now()
            pending[record.id] = Pending(
                record: record,
                firstEdit: date.addingTimeInterval(-maximumInterval),
                lastEdit: date,
                generation: generation(for: record.id),
                sequence: sequence(for: record.id)
            )
        }
        let removals = failedRemovals
        for (id, removal) in removals {
            let generation = generations[id]
            Task { [weak self] in
                guard let self, self.generations[id] == generation else { return }
                try? await self.remove(id, removal: removal)
            }
        }
        schedule()
        Task { [weak self] in await self?.scan() }
    }

    private func generation(for id: UUID) -> UUID {
        if let generation = generations[id] { return generation }
        let generation = UUID()
        generations[id] = generation
        writer.setGeneration(generation, for: id)
        return generation
    }

    private func invalidate(_ id: UUID) {
        pending.removeValue(forKey: id)
        failedRecords.removeValue(forKey: id)
        failedRemovals.removeValue(forKey: id)
        let generation = UUID()
        generations[id] = generation
        writer.setGeneration(generation, for: id)
    }

    private func sequence(for id: UUID) -> UInt64 {
        nextSequence &+= 1
        sequences[id] = nextSequence
        return nextSequence
    }

    private func schedule() {
        timer?.cancel()
        timer = nil
        guard !writeInFlight, let due = pending.values.map({
            min(
                $0.firstEdit.addingTimeInterval(maximumInterval),
                $0.lastEdit.addingTimeInterval(idleInterval)
            )
        }).min() else { return }
        let delay = max(0, due.timeIntervalSince(now()))
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            self.timer = nil
            self.writeDue()
        }
    }

    private func writeDue() {
        let date = now()
        let dueIDs = pending.filter {
            date >= min(
                $0.value.firstEdit.addingTimeInterval(maximumInterval),
                $0.value.lastEdit.addingTimeInterval(idleInterval)
            )
        }.map(\.key)
        let batch = dueIDs.compactMap { pending.removeValue(forKey: $0) }
            .map {
                DraftJournalWrite(record: $0.record, generation: $0.generation, sequence: $0.sequence)
            }
        guard !batch.isEmpty else { schedule(); return }
        writeInFlight = true
        writer.queue.async { [writer, weak self] in
            let results = writer.write(batch)
            Task { @MainActor in
                guard let self else { return }
                self.writeInFlight = false
                self.apply(results)
                self.schedule()
            }
        }
    }

    private func takePending() -> [DraftJournalWrite] {
        let batch = pending.values.map {
            DraftJournalWrite(record: $0.record, generation: $0.generation, sequence: $0.sequence)
        }
        pending = [:]
        return batch
    }

    private func apply(_ results: [DraftJournalWriteResult]) {
        for item in results where generations[item.record.id] == item.generation
            && sequences[item.record.id] == item.sequence {
            switch item.result {
            case .success:
                failures.removeValue(forKey: item.record.id)
                failedRecords.removeValue(forKey: item.record.id)
            case .failure(let error):
                if pending[item.record.id] == nil {
                    failedRecords[item.record.id] = item.record
                }
                failures[item.record.id] = error.localizedDescription
            }
        }
        refreshStatus()
    }

    private func didRemove(
        _ id: UUID, generation: UUID, removal: PendingRemoval, result: Result<Void, any Error>
    ) {
        guard generations[id] == generation else { return }
        switch result {
        case .success:
            recoveredDrafts.removeAll { $0.id == id }
            issues.removeAll { $0.fileURL.lastPathComponent == "\(id.uuidString).json" }
            failures.removeValue(forKey: id)
            failedRemovals.removeValue(forKey: id)
            resolvingIDs.remove(id)
            generations.removeValue(forKey: id)
            sequences.removeValue(forKey: id)
            writer.forgetGeneration(generation, for: id)
        case .failure(let error):
            failures[id] = error.localizedDescription
            // Retrying a failed cleanup is not approval to remove a newer
            // checkpoint that appeared under the same ID in the meantime.
            failedRemovals[id] = removal
        }
        refreshStatus()
    }

    private func refreshStatus() {
        if let failure = failures.sorted(by: { $0.key.uuidString < $1.key.uuidString }).first {
            statusMessage = failure.value
        } else if !issues.isEmpty {
            statusMessage = "Some recovery files could not be opened. Show the recovery folder to inspect them. No files were deleted."
        } else {
            statusMessage = nil
        }
    }
}

private struct DraftJournalWrite: Sendable {
    let record: DraftCheckpoint
    let generation: UUID
    let sequence: UInt64
}

private struct DraftJournalWriteResult: Sendable {
    let record: DraftCheckpoint
    let generation: UUID
    let sequence: UInt64
    let result: Result<DraftCheckpoint?, any Error>
}

private struct DraftJournalScan: Sendable {
    var records: [DraftCheckpoint] = []
    var issues: [DraftRecoveryIssue] = []
}

private enum DraftJournalError: LocalizedError {
    case inaccessible
    case unsafeFile
    case corrupt
    case unsupportedVersion
    case tooLarge
    case tooManyFiles
    case writeFailed
    case readBackFailed
    case cleanupFailed
    case cleanupSourceChanged

    var errorDescription: String? {
        switch self {
        case .inaccessible:
            "The recovery folder could not be opened privately. Your latest writing may not be protected. Check the folder and retry."
        case .unsafeFile:
            "This recovery item is a link or an unsafe file. Show the recovery folder to inspect it. It was not changed."
        case .corrupt:
            "This recovery file is damaged or has invalid fields. Its original bytes were kept. Show the recovery folder to inspect it."
        case .unsupportedVersion:
            "This recovery file needs a different version of Nook. It was kept. Update Nook or inspect the recovery folder."
        case .tooLarge:
            "This draft exceeds the recovery size limit. Save or export your writing directly, then shorten the draft and retry. Existing recovery copies were kept."
        case .tooManyFiles:
            "The recovery folder exceeds the scan limit. Show the folder and move reviewed copies elsewhere, then retry. No files were deleted."
        case .writeFailed:
            "The latest writing could not be protected for recovery. Check available disk space and folder access, then retry. The previous recovery copy was kept."
        case .readBackFailed:
            "The new recovery copy could not be verified. The previous recovery copy was kept. Check the recovery folder and retry."
        case .cleanupFailed:
            "The recovery copy could not be removed. It was kept. Check the recovery folder and retry."
        case .cleanupSourceChanged:
            "This recovery copy changed before it could be removed. It was kept. Review the latest copy before deciding again."
        }
    }
}

/// The directory descriptor anchors every read and atomic replacement. Checking
/// only URL resource values before using Data.write would still follow a link
/// swapped into that path between the check and the write.
private final class DraftJournalWriter: Sendable {
    let queue = DispatchQueue(label: "com.localfirst.nook.draft-journal", qos: .utility)
    let directoryURL: URL
    let limits: DraftJournalLimits
    let now: @Sendable () -> Date
    let beforeFileOperation: @Sendable (DraftJournalFileOperation, URL) throws -> Void
    let trashItem: @Sendable (URL) throws -> Void
    private let generations = Mutex<[UUID: UUID]>([:])

    init(
        directoryURL: URL,
        limits: DraftJournalLimits,
        now: @escaping @Sendable () -> Date,
        beforeFileOperation: @escaping @Sendable (DraftJournalFileOperation, URL) throws -> Void,
        trashItem: @escaping @Sendable (URL) throws -> Void
    ) {
        self.directoryURL = directoryURL
        self.limits = limits
        self.now = now
        self.beforeFileOperation = beforeFileOperation
        self.trashItem = trashItem
    }

    func setGeneration(_ generation: UUID, for id: UUID) {
        generations.withLock { $0[id] = generation }
    }

    func forgetGeneration(_ generation: UUID, for id: UUID) {
        generations.withLock {
            if $0[id] == generation { $0.removeValue(forKey: id) }
        }
    }

    private func isCurrent(_ generation: UUID, for id: UUID) -> Bool {
        generations.withLock { $0[id] == generation }
    }

    func perform<T: Sendable>(
        _ body: @escaping @Sendable (DraftJournalWriter) -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body(self)) }
        }
    }

    func perform<T: Sendable>(
        _ body: @escaping @Sendable (DraftJournalWriter) throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try body(self)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func write(_ batch: [DraftJournalWrite]) -> [DraftJournalWriteResult] {
        batch.map { item in
            DraftJournalWriteResult(
                record: item.record,
                generation: item.generation,
                sequence: item.sequence,
                result: Result { try write(item.record, generation: item.generation) }
            )
        }
    }

    func write(_ input: DraftCheckpoint, generation: UUID) throws -> DraftCheckpoint? {
        guard isCurrent(generation, for: input.id) else { return nil }
        try validate(input)
        let directory = try openDirectory()
        defer { close(directory) }
        let filename = "\(input.id.uuidString).json"
        try verifyExisting(filename, in: directory)
        let destination = directoryURL.appendingPathComponent(filename)
        do { try beforeFileOperation(.write, destination) }
        catch { throw DraftJournalError.writeFailed }
        var record = input
        // This time belongs only to a successfully committed snapshot. It is
        // assigned by the writer, never when a keystroke schedules future work.
        record.checkpointedAt = now()
        let data = try JSONEncoder().encode(record)
        guard data.count <= limits.recordBytes else { throw DraftJournalError.tooLarge }
        let temporary = ".\(UUID().uuidString).tmp"
        let descriptor = openat(directory, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw DraftJournalError.writeFailed }
        defer {
            close(descriptor)
            unlinkat(directory, temporary, 0)
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw DraftJournalError.writeFailed }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw DraftJournalError.writeFailed }
        do {
            try beforeFileOperation(.readBack, destination)
            let verified = try read(temporary, in: directory, expectedID: record.id)
            // String equality ignores Unicode normalization differences. The
            // recovery file must preserve the editor's actual UTF-8 bytes too.
            guard verified.record == record,
                  verified.record.text.utf8.elementsEqual(record.text.utf8),
                  verified.record.baseline.utf8.elementsEqual(record.baseline.utf8) else {
                throw DraftJournalError.readBackFailed
            }
        } catch {
            throw DraftJournalError.readBackFailed
        }
        do { try beforeFileOperation(.replace, destination) }
        catch { throw DraftJournalError.writeFailed }
        guard isCurrent(generation, for: input.id) else { return nil }
        try verifyExisting(filename, in: directory)
        guard renameat(directory, temporary, directory, filename) == 0 else {
            throw DraftJournalError.writeFailed
        }
        // fsync on the private directory requests persistence of the rename.
        // Filesystem/power-loss guarantees still require separate validation.
        _ = fsync(directory)
        return record
    }

    func remove(_ id: UUID, toTrash: Bool, expected: DraftCheckpoint? = nil) throws {
        let directory = try openDirectory()
        defer { close(directory) }
        let filename = "\(id.uuidString).json"
        var info = stat()
        guard fstatat(directory, filename, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw DraftJournalError.cleanupFailed
        }
        guard isPrivateRegularFile(info) else { throw DraftJournalError.unsafeFile }
        let original = try read(filename, in: directory, expectedID: id)
        if let expected {
            guard original.record == expected,
                  original.record.text.utf8.elementsEqual(expected.text.utf8),
                  original.record.baseline.utf8.elementsEqual(expected.baseline.utf8) else {
                throw DraftJournalError.cleanupSourceChanged
            }
        }
        let expectedRevision = original.revision
        let url = directoryURL.appendingPathComponent(filename)
        do {
            try beforeFileOperation(.remove, url)
            // Permanent cleanup can race a replaced recovery just as Trash
            // can. Check exact bytes as well as the inode so an in-place edit
            // does not become permission to remove unseen writing.
            guard try read(filename, in: directory, expectedID: id).revision == expectedRevision else {
                throw DraftJournalError.cleanupSourceChanged
            }
            try verifyRemovalSource(directory: directory, filename: filename, expected: info)
            if toTrash {
                // Cocoa's reversible Trash API takes a pathname, unlike the
                // descriptor-relative unlink below. Refuse a moved directory
                // or replaced source immediately before handing it to Cocoa.
                // This is still not a security boundary against another process
                // running as this same user and racing the subsequent API call.
                try trashItem(url)
            } else {
                guard unlinkat(directory, filename, 0) == 0 else {
                    throw DraftJournalError.cleanupFailed
                }
            }
            var remaining = stat()
            guard fstatat(directory, filename, &remaining, AT_SYMLINK_NOFOLLOW) != 0,
                  errno == ENOENT else { throw DraftJournalError.cleanupFailed }
            _ = fsync(directory)
        } catch DraftJournalError.cleanupSourceChanged {
            throw DraftJournalError.cleanupSourceChanged
        } catch {
            throw DraftJournalError.cleanupFailed
        }
    }

    func scan() -> DraftJournalScan {
        var result = DraftJournalScan()
        do {
            let directory = try openDirectory()
            defer { close(directory) }
            let copy = dup(directory)
            guard copy >= 0, let stream = fdopendir(copy) else {
                if copy >= 0 { close(copy) }
                throw DraftJournalError.inaccessible
            }
            defer { closedir(stream) }
            var examined = 0
            var totalBytes = 0
            while let entry = readdir(stream) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                        String(cString: $0)
                    }
                }
                guard name != ".", name != "..", name != ".DS_Store" else { continue }
                examined += 1
                guard examined <= limits.recordCount else {
                    throw DraftJournalError.tooManyFiles
                }
                let url = directoryURL.appendingPathComponent(name)
                do {
                    var info = stat()
                    guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                          isPrivateRegularFile(info) else {
                        throw DraftJournalError.unsafeFile
                    }
                    guard name.hasSuffix(".json"),
                          let id = UUID(uuidString: String(name.dropLast(5))),
                          name == "\(id.uuidString).json" else {
                        throw DraftJournalError.corrupt
                    }
                    guard info.st_size >= 0, info.st_size <= limits.recordBytes else {
                        throw DraftJournalError.tooLarge
                    }
                    guard Int(info.st_size) <= limits.scanBytes - totalBytes else {
                        throw DraftJournalError.tooManyFiles
                    }
                    // Charge attempted reads even when decoding fails. A folder
                    // of large corrupt files must not bypass the scan budget.
                    // Capping this read at its reserved size also prevents a
                    // concurrently growing file from consuming another draft's
                    // share of the budget.
                    let reservedBytes = Int(info.st_size)
                    totalBytes += reservedBytes
                    let decoded = try read(
                        name, in: directory, expectedID: id,
                        maximumBytes: reservedBytes
                    )
                    result.records.append(decoded.record)
                } catch {
                    result.issues.append(DraftRecoveryIssue(fileURL: url, message: error.localizedDescription))
                }
            }
        } catch {
            result.issues.append(DraftRecoveryIssue(fileURL: directoryURL, message: error.localizedDescription))
        }
        return result
    }

    private func openDirectory() throws -> Int32 {
        let manager = FileManager.default
        let parent = directoryURL.deletingLastPathComponent()
        do {
            try manager.createDirectory(
                at: parent, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch { throw DraftJournalError.inaccessible }
        if mkdir(directoryURL.path, 0o700) != 0, errno != EEXIST {
            throw DraftJournalError.inaccessible
        }
        let descriptor = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw DraftJournalError.inaccessible }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
              (info.st_mode & S_IFMT) == S_IFDIR,
              fchmod(descriptor, 0o700) == 0 else {
            close(descriptor)
            throw DraftJournalError.inaccessible
        }
        return descriptor
    }

    private func verifyExisting(_ filename: String, in directory: Int32) throws {
        var info = stat()
        if fstatat(directory, filename, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard isPrivateRegularFile(info) else { throw DraftJournalError.unsafeFile }
        } else if errno != ENOENT {
            throw DraftJournalError.inaccessible
        }
    }

    private func verifyRemovalSource(directory: Int32, filename: String, expected: stat) throws {
        var openedDirectory = stat()
        var namedDirectory = stat()
        var openedSource = stat()
        var namedSource = stat()
        guard fstat(directory, &openedDirectory) == 0,
              lstat(directoryURL.path, &namedDirectory) == 0,
              (namedDirectory.st_mode & S_IFMT) == S_IFDIR,
              openedDirectory.st_dev == namedDirectory.st_dev,
              openedDirectory.st_ino == namedDirectory.st_ino,
              fstatat(directory, filename, &openedSource, AT_SYMLINK_NOFOLLOW) == 0,
              lstat(directoryURL.appendingPathComponent(filename).path, &namedSource) == 0,
              isPrivateRegularFile(namedSource), isPrivateRegularFile(openedSource),
              openedSource.st_dev == expected.st_dev, openedSource.st_ino == expected.st_ino,
              namedSource.st_dev == expected.st_dev, namedSource.st_ino == expected.st_ino else {
            throw DraftJournalError.unsafeFile
        }
    }

    private func isPrivateRegularFile(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == getuid()
            && info.st_nlink == 1 && (info.st_mode & 0o077) == 0
    }

    private func read(
        _ filename: String, in directory: Int32, expectedID: UUID,
        maximumBytes: Int? = nil
    ) throws -> (record: DraftCheckpoint, bytes: Int, revision: Data) {
        let descriptor = openat(directory, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw DraftJournalError.unsafeFile }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, isPrivateRegularFile(info) else {
            throw DraftJournalError.unsafeFile
        }
        let maximum = min(limits.recordBytes, maximumBytes ?? limits.recordBytes)
        guard info.st_size >= 0, info.st_size <= maximum else {
            throw DraftJournalError.tooLarge
        }
        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let requested = min(bytes.count, maximum - data.count + 1)
            let count = bytes.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, requested)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw DraftJournalError.corrupt }
            if count == 0 { break }
            guard data.count + count <= maximum else { throw DraftJournalError.tooLarge }
            data.append(contentsOf: bytes.prefix(count))
        }
        let record: DraftCheckpoint
        struct Version: Decodable { let version: Int }
        let version: Int
        do { version = try JSONDecoder().decode(Version.self, from: data).version }
        catch { throw DraftJournalError.corrupt }
        guard version == 1 else { throw DraftJournalError.unsupportedVersion }
        do { record = try JSONDecoder().decode(DraftCheckpoint.self, from: data) }
        catch { throw DraftJournalError.corrupt }
        guard record.id == expectedID else { throw DraftJournalError.corrupt }
        try validate(record)
        return (record, data.count, MeetingNote.contentRevision(data))
    }

    private func validate(_ record: DraftCheckpoint) throws {
        guard record.version == 1 else { throw DraftJournalError.unsupportedVersion }
        func validPath(_ path: String) -> Bool {
            path.hasPrefix("/") && !path.contains("\0") && path.utf8.count <= 32_768
                && URL(fileURLWithPath: path).standardizedFileURL.path == path
        }
        guard validPath(record.libraryPath),
              record.originalFilePath.map(validPath) ?? true,
              record.title.utf8.count <= 65_536,
              record.baselineRevision.map({ $0.count == 32 }) ?? true,
              record.createdAt.timeIntervalSince1970.isFinite,
              record.checkpointedAt.timeIntervalSince1970.isFinite else {
            throw DraftJournalError.corrupt
        }
        if let completion = record.completion {
            guard validPath(completion.targetPath), completion.revision.count == 32 else {
                throw DraftJournalError.corrupt
            }
        }
        guard record.estimatedBytes <= limits.recordBytes else { throw DraftJournalError.tooLarge }
    }
}
