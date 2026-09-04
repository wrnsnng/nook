import Darwin
import Foundation
import Synchronization

struct StorageInventoryLocation: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case notes, interruptedSaves, recordings, drafts, searchCache, appCache, eventLog, developerLog
    }

    enum Scope: Hashable, Sendable {
        case file
        case markdownFiles
        case interruptedSaveFiles
        case directFiles
        case directoryTree
    }

    let id: Kind
    let url: URL
    let scope: Scope

    var title: String {
        switch id {
        case .notes: "Notes"
        case .interruptedSaves: "Temporary save copies"
        case .recordings: "Meeting recordings"
        case .drafts: "Draft recovery"
        case .searchCache: "Ask search cache"
        case .appCache: "App caches"
        case .eventLog: "Event log"
        case .developerLog: "Developer log"
        }
    }

    var detail: String {
        switch id {
        case .notes: "Markdown files directly in the current notes folder."
        case .interruptedSaves: "Known temporary save files in this notes folder. They may contain unfinished writing. Review them before deciding what to keep."
        case .recordings: "Kept audio, unfinished recordings, and their recovery files."
        case .drafts: "Recovery copies of unfinished writing, including current drafts."
        case .searchCache: "Derived search vectors. This cache is shared by Nook installations on this Mac."
        case .appCache: "Caches for this Nook installation, including update downloads when present."
        case .eventLog: "The local operational event log for this Nook installation."
        case .developerLog: "A legacy developer log, if present. It can contain sensitive diagnostics."
        }
    }

    var canReviewInLibrary: Bool { id == .notes || id == .recordings || id == .drafts }

    @MainActor
    static func current(notesDirectory: URL, draftsDirectory: URL) -> [Self] {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let identity = Bundle.main.bundleIdentifier ?? "com.localfirst.nook.dev"
        // Do not call recordingsDirectory() or defaultCacheURL(): those APIs
        // create directories. An inventory must not create the storage it counts.
        return [
            Self(id: .notes, url: notesDirectory, scope: .markdownFiles),
            Self(id: .interruptedSaves, url: notesDirectory, scope: .interruptedSaveFiles),
            Self(id: .recordings, url: notesDirectory.appendingPathComponent(".recordings"), scope: .directoryTree),
            Self(id: .drafts, url: draftsDirectory, scope: .directFiles),
            Self(id: .searchCache, url: support.appendingPathComponent("NookAsk/chunks.json"), scope: .file),
            Self(id: .appCache, url: caches.appendingPathComponent(identity), scope: .directoryTree),
            Self(id: .eventLog, url: NookEventLog.url, scope: .file),
            Self(id: .developerLog, url: home.appendingPathComponent("Library/Logs/nook-debug.log"), scope: .file)
        ]
    }
}

struct StorageInventoryEntry: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable { case complete, missing, partial, unavailable }
    enum Warning: String, CaseIterable, Hashable, Sendable {
        case scanLimit = "The scan reached its time, depth, or file limit. This is a partial count."
        case links = "Symbolic links were not followed or counted."
        case specialFiles = "Non-regular files were not counted."
        case metadata = "Some file metadata could not be read. This is a partial count."
        case notDirectory = "This location is blocked by an item that is not a folder."
        case mountedFolder = "A folder on another volume was not scanned."
        case sizeOverflow = "The total is too large to represent. This is a partial count."
    }

    let location: StorageInventoryLocation
    var fileCount = 0
    var bytes: Int64 = 0
    var status = Status.complete
    var warnings: Set<Warning> = []
    /// A small Finder selection makes hidden staging files discoverable
    /// without collecting an unbounded file listing or exposing their contents.
    var sampleFiles: [URL] = []
    var id: StorageInventoryLocation.Kind { location.id }
}

struct StorageInventoryLimits: Sendable {
    var entries = 50_000
    var depth = 8
    var seconds: TimeInterval = 5
}

final class StorageInventoryCancellation: Sendable {
    private let cancelled = Mutex(false)
    var isCancelled: Bool { cancelled.withLock { $0 } }
    func cancel() { cancelled.withLock { $0 = true } }
}

/// Sizes come only from lstat/fstatat metadata. Directory descriptors anchor
/// traversal, every component is opened without following links, and no
/// regular file is opened or decoded. Counts are logical bytes, not uniquely
/// allocated disk space: sparse files, clones and hard links can differ.
enum StorageInventoryScanner {
    static func scan(
        _ locations: [StorageInventoryLocation],
        limits: StorageInventoryLimits = StorageInventoryLimits(),
        cancellation: StorageInventoryCancellation,
        now: @escaping @Sendable () -> TimeInterval = {
            Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        },
        beforeOpeningComponent: @Sendable (String) -> Void = { _ in }
    ) -> [StorageInventoryEntry] {
        var budget = Budget(limits: limits, now: now)
        var entries: [StorageInventoryEntry] = []
        for location in locations {
            if cancellation.isCancelled { break }
            var entry = StorageInventoryEntry(location: location)
            guard location.url.isFileURL, !location.url.path.utf8.contains(0) else {
                entry.status = .unavailable
                entry.warnings.insert(.metadata)
                entries.append(entry)
                continue
            }
            guard !budget.expired else {
                entry.status = .partial
                entry.warnings.insert(.scanLimit)
                entries.append(entry)
                continue
            }
            do {
                if location.scope == .file {
                    let parent = try openDirectory(
                        location.url.deletingLastPathComponent(), budget: budget,
                        cancellation: cancellation, beforeOpeningComponent: beforeOpeningComponent
                    )
                    defer { close(parent) }
                    try budget.check(cancellation)
                    var metadata = stat()
                    guard fstatat(parent, location.url.lastPathComponent, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                        throw MetadataError(code: errno)
                    }
                    budget.visited += 1
                    count(metadata, into: &entry)
                } else {
                    let directory = try openDirectory(
                        location.url, budget: budget, cancellation: cancellation,
                        beforeOpeningComponent: beforeOpeningComponent
                    )
                    defer { close(directory) }
                    try budget.check(cancellation)
                    var metadata = stat()
                    guard fstat(directory, &metadata) == 0 else { throw MetadataError(code: errno) }
                    walk(
                        directory, rootDevice: metadata.st_dev, depth: 0,
                        entry: &entry, budget: &budget, cancellation: cancellation
                    )
                }
            } catch ScanStopped.cancelled {
                return []
            } catch ScanStopped.limit {
                entry.status = .partial
                entry.warnings.insert(.scanLimit)
            } catch let error as MetadataError {
                if error.code == ENOENT {
                    entry.status = .missing
                } else {
                    entry.status = .unavailable
                    switch error.code {
                    case ELOOP: entry.warnings.insert(.links)
                    case ENOTDIR: entry.warnings.insert(.notDirectory)
                    default: entry.warnings.insert(.metadata)
                    }
                }
            } catch {
                entry.status = .unavailable
                entry.warnings.insert(.metadata)
            }
            if !entry.warnings.isEmpty, entry.status == .complete { entry.status = .partial }
            entries.append(entry)
        }
        return entries
    }

    private static func walk(
        _ descriptor: Int32,
        rootDevice: dev_t,
        depth: Int,
        entry: inout StorageInventoryEntry,
        budget: inout Budget,
        cancellation: StorageInventoryCancellation
    ) {
        let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
        guard copy >= 0 else { entry.warnings.insert(.metadata); return }
        guard let directory = fdopendir(copy) else {
            close(copy)
            entry.warnings.insert(.metadata)
            return
        }
        defer { closedir(directory) }
        while !cancellation.isCancelled {
            if budget.expired { entry.warnings.insert(.scanLimit); return }
            errno = 0
            guard let item = readdir(directory) else {
                if errno != 0 { entry.warnings.insert(.metadata) }
                return
            }
            guard let name = withUnsafeBytes(of: item.pointee.d_name, { bytes in
                String(bytes: bytes.prefix(while: { $0 != 0 }), encoding: .utf8)
            }) else {
                budget.visited += 1
                entry.warnings.insert(.metadata)
                continue
            }
            guard name != ".", name != ".." else { continue }
            budget.visited += 1
            if entry.location.scope == .markdownFiles,
               (name.hasPrefix(".") || !(name as NSString).pathExtension.lowercased().elementsEqual("md")) {
                continue
            }
            if entry.location.scope == .interruptedSaveFiles, !isSaveStage(name) { continue }
            var metadata = stat()
            guard fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                entry.warnings.insert(.metadata)
                continue
            }
            if metadata.st_mode & S_IFMT == S_IFDIR {
                guard entry.location.scope == .directoryTree else { continue }
                guard depth < budget.limits.depth else { entry.warnings.insert(.scanLimit); continue }
                guard metadata.st_dev == rootDevice else { entry.warnings.insert(.mountedFolder); continue }
                let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { entry.warnings.insert(.metadata); continue }
                var opened = stat()
                if fstat(child, &opened) == 0,
                   opened.st_ino == metadata.st_ino, opened.st_dev == metadata.st_dev {
                    walk(child, rootDevice: rootDevice, depth: depth + 1,
                         entry: &entry, budget: &budget, cancellation: cancellation)
                } else {
                    entry.warnings.insert(.metadata)
                }
                close(child)
            } else {
                count(metadata, into: &entry)
                if entry.location.scope == .interruptedSaveFiles,
                   metadata.st_mode & S_IFMT == S_IFREG, entry.sampleFiles.count < 5 {
                    entry.sampleFiles.append(entry.location.url.appendingPathComponent(name))
                }
            }
        }
    }

    private static func isSaveStage(_ name: String) -> Bool {
        guard name.hasSuffix(".tmp") else { return false }
        for prefix in [".nook-write-", ".nook-recovery-"] where name.hasPrefix(prefix) {
            let identifier = String(name.dropFirst(prefix.count).dropLast(4))
            return identifier.utf8.count == 36 && UUID(uuidString: identifier) != nil
        }
        return false
    }

    private static func count(_ metadata: stat, into entry: inout StorageInventoryEntry) {
        switch metadata.st_mode & S_IFMT {
        case S_IFREG:
            guard metadata.st_size >= 0 else { entry.warnings.insert(.metadata); return }
            let sum = entry.bytes.addingReportingOverflow(metadata.st_size)
            guard !sum.overflow else { entry.warnings.insert(.sizeOverflow); return }
            entry.fileCount += 1
            entry.bytes = sum.partialValue
        case S_IFLNK:
            entry.warnings.insert(.links)
        default:
            entry.warnings.insert(.specialFiles)
        }
    }

    private static func openDirectory(
        _ url: URL,
        budget: Budget,
        cancellation: StorageInventoryCancellation,
        beforeOpeningComponent: @Sendable (String) -> Void
    ) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0) else {
            throw MetadataError(code: EINVAL)
        }
        try budget.check(cancellation)
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw MetadataError(code: errno) }
        // The descriptor belongs here until every component is accepted.
        // Cancellation or a budget expiry must close the last opened parent.
        defer { if descriptor >= 0 { close(descriptor) } }
        // Foundation standardization can turn physical /private/var back into
        // the /var symlink on macOS. Traverse the supplied absolute components
        // verbatim: never introduce a link, and never resolve a user's link.
        for component in url.pathComponents where component != "/" {
            try budget.check(cancellation)
            beforeOpeningComponent(component)
            try budget.check(cancellation)
            let child = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let error = errno
            if child < 0 {
                if error == ENOTDIR {
                    // Darwin can report ENOTDIR for a link rejected by
                    // O_NOFOLLOW, but an ordinary file obstructing the path
                    // produces it too. Only actual no-follow metadata can
                    // distinguish those without resolving the target.
                    try budget.check(cancellation)
                    var metadata = stat()
                    if fstatat(descriptor, component, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
                       metadata.st_mode & S_IFMT == S_IFLNK {
                        throw MetadataError(code: ELOOP)
                    }
                }
                throw MetadataError(code: error)
            }
            close(descriptor)
            descriptor = child
        }
        try budget.check(cancellation)
        let result = descriptor
        descriptor = -1
        return result
    }

    private struct MetadataError: Error { let code: Int32 }
    private enum ScanStopped: Error { case cancelled, limit }
    private struct Budget {
        let limits: StorageInventoryLimits
        let now: @Sendable () -> TimeInterval
        let start: TimeInterval
        var visited = 0

        init(limits: StorageInventoryLimits, now: @escaping @Sendable () -> TimeInterval) {
            self.limits = limits
            self.now = now
            start = now()
        }

        var expired: Bool {
            visited >= max(0, limits.entries)
                || !limits.seconds.isFinite || limits.seconds <= 0
                || now() - start >= limits.seconds
        }

        func check(_ cancellation: StorageInventoryCancellation) throws {
            if cancellation.isCancelled { throw ScanStopped.cancelled }
            if expired { throw ScanStopped.limit }
        }
    }
}

@MainActor
final class StorageInventoryController: ObservableObject {
    enum Phase: Equatable {
        case idle, scanning, complete, cancelled

        var label: String {
            switch self {
            case .idle: "Ready to count file sizes"
            case .scanning: "Counting file sizes…"
            case .complete: "Current storage snapshot"
            case .cancelled: "Scan cancelled"
            }
        }
    }

    @Published private(set) var entries: [StorageInventoryEntry] = []
    @Published private(set) var phase: Phase = .idle
    var isScanning: Bool { phase == .scanning }
    private var generation = UUID()
    private let worker: StorageInventoryWorker

    init(scan: @escaping StorageInventoryWorker.Scan = { locations, cancellation in
        StorageInventoryScanner.scan(locations, cancellation: cancellation)
    }) {
        worker = StorageInventoryWorker(scan: scan)
    }

    func prepareForPresentation() {
        generation = UUID()
        worker.cancel()
        entries = []
        phase = .idle
    }

    func refresh(_ locations: [StorageInventoryLocation]) {
        let generation = UUID()
        self.generation = generation
        entries = []
        phase = .scanning
        worker.submit(locations) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.entries = result
                self.phase = .complete
            }
        }
    }

    func cancel() {
        generation = UUID()
        worker.cancel()
        if isScanning { phase = .cancelled }
    }

    deinit { worker.cancel() }
}

/// One active scan and one replaceable pending request. A stalled filesystem
/// call cannot freeze Settings or cause Refresh to accumulate worker threads.
/// Cancellation is checked between metadata calls; it cannot interrupt an
/// individual kernel/filesystem operation already in progress.
final class StorageInventoryWorker: Sendable {
    typealias Scan = @Sendable ([StorageInventoryLocation], StorageInventoryCancellation) -> [StorageInventoryEntry]
    private struct Request: Sendable {
        let locations: [StorageInventoryLocation]
        let cancellation = StorageInventoryCancellation()
        let completion: @Sendable ([StorageInventoryEntry]) -> Void
    }
    private struct State {
        var active: StorageInventoryCancellation?
        var pending: Request?
        var running = false
    }
    private let state = Mutex(State())
    private let scan: Scan

    init(scan: @escaping Scan) { self.scan = scan }

    func submit(
        _ locations: [StorageInventoryLocation],
        completion: @escaping @Sendable ([StorageInventoryEntry]) -> Void
    ) {
        let shouldStart = state.withLock { state in
            state.active?.cancel()
            state.pending?.cancellation.cancel()
            state.pending = Request(locations: locations, completion: completion)
            if state.running { return false }
            state.running = true
            return true
        }
        if shouldStart {
            let work: @Sendable () -> Void = { self.drain() }
            DispatchQueue.global(qos: .utility).async(execute: work)
        }
    }

    func cancel() {
        state.withLock { state in
            state.active?.cancel()
            state.pending?.cancellation.cancel()
            state.pending = nil
        }
    }

    private func drain() {
        while let request = state.withLock({ state -> Request? in
            guard let request = state.pending else {
                state.active = nil
                state.running = false
                return nil
            }
            state.pending = nil
            state.active = request.cancellation
            return request
        }) {
            let result = scan(request.locations, request.cancellation)
            if !request.cancellation.isCancelled { request.completion(result) }
        }
    }
}
