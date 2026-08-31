import Darwin
import Foundation
import Synchronization
import Testing
@testable import Nook

struct StorageInventoryTests {
    @Test
    func cancellationDuringPathTraversalDoesNotOpenTheRemainingComponents() throws {
        let fixture = try InventoryFixture()
        defer { fixture.remove() }
        try fixture.directory("stop-here/never-visited")
        try fixture.file("stop-here/never-visited/note.md", bytes: 10)
        let cancellation = StorageInventoryCancellation()
        let visited = Mutex<[String]>([])
        let result = StorageInventoryScanner.scan(
            [StorageInventoryLocation(id: .notes, url: fixture.url("stop-here/never-visited"), scope: .markdownFiles)],
            cancellation: cancellation,
            beforeOpeningComponent: { component in
                visited.withLock { $0.append(component) }
                if component == "stop-here" { cancellation.cancel() }
            }
        )
        #expect(result.isEmpty)
        #expect(visited.withLock { $0.contains("stop-here") })
        #expect(visited.withLock { !$0.contains("never-visited") })
    }

    @Test
    func anElapsedBudgetDuringPathTraversalStopsBeforeFurtherFilesystemOperations() throws {
        let fixture = try InventoryFixture()
        defer { fixture.remove() }
        try fixture.directory("stop-here/never-visited")
        let time = Mutex<TimeInterval>(0)
        let visited = Mutex<[String]>([])
        let result = StorageInventoryScanner.scan(
            [StorageInventoryLocation(id: .notes, url: fixture.url("stop-here/never-visited"), scope: .markdownFiles)],
            limits: StorageInventoryLimits(entries: 100, depth: 8, seconds: 1),
            cancellation: StorageInventoryCancellation(),
            now: { time.withLock { $0 } },
            beforeOpeningComponent: { component in
                visited.withLock { $0.append(component) }
                if component == "stop-here" { time.withLock { $0 = 2 } }
            }
        )
        let entry = try #require(result.first)
        #expect(entry.status == .partial)
        #expect(entry.warnings == [.scanLimit])
        #expect(entry.fileCount == 0)
        #expect(visited.withLock { !$0.contains("never-visited") })
    }

    @Test(arguments: [false, true])
    func anOrdinaryFileObstructingADirectoryIsNotReportedAsASymbolicLink(intermediate: Bool) throws {
        let fixture = try InventoryFixture()
        defer { fixture.remove() }
        try fixture.file("ordinary-file", bytes: 10)
        let path = intermediate ? "ordinary-file/nested" : "ordinary-file"
        let entry = try #require(scan(StorageInventoryLocation(
            id: .notes, url: fixture.url(path), scope: .markdownFiles
        )).first)
        #expect(entry.status == .unavailable)
        #expect(entry.warnings == [.notDirectory])
        #expect(entry.bytes == 0)
    }

    @Test
    func aPhysicalTemporaryPathIsNotStandardizedBackThroughTheVarSymlink() throws {
        let fixture = try InventoryFixture()
        defer { fixture.remove() }
        try fixture.file("one.md", bytes: 13)
        let entry = try #require(scan(fixture.location(.notes, scope: .markdownFiles)).first)
        #expect(entry.status == .complete)
        #expect(entry.bytes == 13)
        #expect(entry.location.url.path == fixture.root.path)
    }

    @Test
    func interruptedSavesIncludeOnlyKnownUuidStagingNamesAndKeepAFiniteFinderSelection() throws {
        let fixture = try InventoryFixture()
        defer { fixture.remove() }
        for index in 0..<7 {
            let prefix = index.isMultiple(of: 2) ? ".nook-write-" : ".nook-recovery-"
            try fixture.file("\(prefix)\(UUID().uuidString).tmp", bytes: 10)
        }
        try fixture.file(".nook-write-not-a-uuid.tmp", bytes: 100)
        try fixture.file(".nook-write-\(UUID().uuidString).backup", bytes: 200)
        try fixture.file(".unrelated-hidden.tmp", bytes: 300)
        let entry = try #require(scan(fixture.location(.interruptedSaves, scope: .interruptedSaveFiles)).first)
        #expect(entry.status == .complete)
        #expect(entry.fileCount == 7)
        #expect(entry.bytes == 70)
        #expect(entry.sampleFiles.count == 5)
        #expect(entry.sampleFiles.allSatisfy { $0.deletingLastPathComponent() == fixture.root })
        #expect(!entry.location.canReviewInLibrary)
        #expect(FileManager.default.fileExists(atPath: fixture.url(".unrelated-hidden.tmp").path))
    }

    @Test
    func notesCountOnlyDirectVisibleMarkdownFilesWithoutReadingTheirContents() throws {
        let fixture = try InventoryFixture()
        defer { fixture.remove() }
        try fixture.file("one.md", bytes: 12, mode: 0o000)
        try fixture.file("two.MD", bytes: 23)
        try fixture.file(".hidden.md", bytes: 300)
        try fixture.file("other.txt", bytes: 400)
        try fixture.directory("nested")
        try fixture.file("nested/not-in-library.md", bytes: 500)
        let entry = try #require(scan(fixture.location(.notes, scope: .markdownFiles)).first)
        #expect(entry.status == .complete)
        #expect(entry.fileCount == 2)
        #expect(entry.bytes == 35)
        #expect(entry.warnings.isEmpty)
        // The unreadable file is deliberately not even valid Markdown. Its
        // metadata alone must be enough, and inventory must not change mode.
        var metadata = stat()
        #expect(lstat(fixture.url("one.md").path, &metadata) == 0)
        #expect(metadata.st_mode & 0o777 == 0)
    }

    @Test
    func recordingsIncludeUnfinishedPartsAndRecoveryFiles() throws {
        let fixture = try InventoryFixture()
        defer { fixture.remove() }
        try fixture.file("synthetic.m4a", bytes: 11)
        try fixture.file("synthetic.mp4", bytes: 22)
        try fixture.file("synthetic.part-1.mp4", bytes: 33)
        try fixture.file("synthetic.notes.txt", bytes: 44)
        try fixture.file(".unfinished", bytes: 55)
        let entry = try #require(scan(fixture.location(.recordings, scope: .directFiles)).first)
        #expect(entry.fileCount == 5)
        #expect(entry.bytes == 165)
        #expect(entry.status == .complete)
    }

    @Test
    func draftCountsIncludeCorruptAndTemporaryCopiesWithoutDecodingOrDeletingThem() throws {
        let fixture = try InventoryFixture()
        defer { fixture.remove() }
        try fixture.file("corrupt.json", bytes: 17)
        try fixture.file(".checkpoint.tmp", bytes: 29)
        let location = fixture.location(.drafts, scope: .directFiles)
        let entry = try #require(scan(location).first)
        #expect(entry.fileCount == 2)
        #expect(entry.bytes == 46)
        #expect(FileManager.default.fileExists(atPath: fixture.url("corrupt.json").path))
        #expect(FileManager.default.fileExists(atPath: fixture.url(".checkpoint.tmp").path))
    }

    @Test
    func exactFileScopesDoNotIncludeTheirNeighbors() throws {
        let fixture = try InventoryFixture()
        defer { fixture.remove() }
        try fixture.file("current.log", bytes: 31)
        try fixture.file("another-app.log", bytes: 400)
        let location = StorageInventoryLocation(id: .eventLog, url: fixture.url("current.log"), scope: .file)
        let entry = try #require(scan(location).first)
        #expect(entry.bytes == 31)
        #expect(entry.fileCount == 1)
        #expect(entry.location.url == fixture.url("current.log"))
    }

    @Test
    func missingLocationsRemainMissingAndAreNeverCreatedByTheOverview() throws {
        let fixture = try InventoryFixture()
        defer { fixture.remove() }
        let missing = fixture.url("missing-folder")
        let location = StorageInventoryLocation(id: .appCache, url: missing, scope: .directoryTree)
        let entry = try #require(scan(location).first)
        #expect(entry.status == .missing)
        #expect(entry.bytes == 0)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test
    func linksAndSpecialFilesAreNotFollowedOrOpened() throws {
        let fixture = try InventoryFixture()
        defer { fixture.remove() }
        try fixture.file("kept", bytes: 10)
        try FileManager.default.createSymbolicLink(at: fixture.url("linked-file"), withDestinationURL: fixture.url("kept"))
        try FileManager.default.createSymbolicLink(at: fixture.url("loop"), withDestinationURL: fixture.root)
        #expect(mkfifo(fixture.url("pipe").path, 0o600) == 0)
        let entry = try #require(scan(fixture.location(.appCache, scope: .directoryTree)).first)
        #expect(entry.bytes == 10)
        #expect(entry.fileCount == 1)
        #expect(entry.status == .partial)
        #expect(entry.warnings.contains(.links))
        #expect(entry.warnings.contains(.specialFiles))
    }

    @Test(arguments: [false, true])
    func aLinkedRootOrIntermediateDirectoryCannotExpandTheInventoryScope(intermediate: Bool) throws {
        let fixture = try InventoryFixture()
        defer { fixture.remove() }
        try fixture.directory("real/nested")
        try fixture.file("real/secret.md", bytes: 100)
        try fixture.file("real/nested/secret.md", bytes: 200)
        try FileManager.default.createSymbolicLink(at: fixture.url("linked"), withDestinationURL: fixture.url("real"))
        let location = StorageInventoryLocation(
            id: .notes,
            url: fixture.url(intermediate ? "linked/nested" : "linked"),
            scope: .markdownFiles
        )
        let entry = try #require(scan(location).first)
        #expect(entry.status == .unavailable)
        #expect(entry.bytes == 0)
        #expect(entry.fileCount == 0)
        #expect(entry.warnings.contains(.links))
    }

    @Test
    func anExactFileScopeRefusesASymlink() throws {
        let fixture = try InventoryFixture()
        defer { fixture.remove() }
        try fixture.file("actual", bytes: 100)
        try FileManager.default.createSymbolicLink(at: fixture.url("alias"), withDestinationURL: fixture.url("actual"))
        let entry = try #require(scan(StorageInventoryLocation(id: .eventLog, url: fixture.url("alias"), scope: .file)).first)
        #expect(entry.fileCount == 0)
        #expect(entry.bytes == 0)
        #expect(entry.status == .partial)
        #expect(entry.warnings.contains(.links))
    }

    @Test
    func recursiveCachesIncludeNestedFilesWithinTheDepthLimit() throws {
        let fixture = try InventoryFixture()
        defer { fixture.remove() }
        try fixture.file("root", bytes: 10)
        try fixture.directory("one/two")
        try fixture.file("one/child", bytes: 20)
        try fixture.file("one/two/deeper", bytes: 30)
        let location = fixture.location(.appCache, scope: .directoryTree)
        let entry = try #require(scan(location).first)
        #expect(entry.status == .complete)
        #expect(entry.bytes == 60)
        #expect(entry.fileCount == 3)
        let bounded = try #require(StorageInventoryScanner.scan(
            [location], limits: StorageInventoryLimits(entries: 100, depth: 1, seconds: 5),
            cancellation: StorageInventoryCancellation()
        ).first)
        #expect(bounded.status == .partial)
        #expect(bounded.bytes == 30)
        #expect(bounded.warnings.contains(.scanLimit))
    }

    @Test
    func theEntryBudgetBoundsWorkAcrossAllLocationsAndLabelsPartialResults() throws {
        let fixture = try InventoryFixture()
        defer { fixture.remove() }
        for index in 0..<20 { try fixture.file("\(index).md", bytes: 10) }
        let result = StorageInventoryScanner.scan(
            [fixture.location(.notes, scope: .markdownFiles), fixture.location(.drafts, scope: .directFiles)],
            limits: StorageInventoryLimits(entries: 3, depth: 8, seconds: 5),
            cancellation: StorageInventoryCancellation()
        )
        #expect(result.count == 2)
        #expect(result.reduce(0) { $0 + $1.fileCount } == 3)
        #expect(result.allSatisfy { $0.status == .partial && $0.warnings.contains(.scanLimit) })
    }

    @Test
    func anExpiredTimeBudgetReportsPartialInsteadOfAnEmptySuccessfulScan() throws {
        let fixture = try InventoryFixture()
        defer { fixture.remove() }
        try fixture.file("one.md", bytes: 20)
        let entry = try #require(StorageInventoryScanner.scan(
            [fixture.location(.notes, scope: .markdownFiles)],
            limits: StorageInventoryLimits(entries: 100, depth: 8, seconds: 0),
            cancellation: StorageInventoryCancellation()
        ).first)
        #expect(entry.status == .partial)
        #expect(entry.fileCount == 0)
        #expect(entry.warnings.contains(.scanLimit))
    }

    @Test
    func cancellationBeforeScanningDoesNoInventoryWork() throws {
        let fixture = try InventoryFixture()
        defer { fixture.remove() }
        let cancellation = StorageInventoryCancellation()
        cancellation.cancel()
        #expect(StorageInventoryScanner.scan(
            [fixture.location(.notes, scope: .markdownFiles)], cancellation: cancellation
        ).isEmpty)
    }

    @Test @MainActor
    func currentLocationsUseTheCapturedLibraryAndDraftsWithoutBroadHomeScanning() {
        let locations = StorageInventoryLocation.current(
            notesDirectory: URL(fileURLWithPath: "/synthetic/current-library"),
            draftsDirectory: URL(fileURLWithPath: "/synthetic/current-drafts")
        )
        #expect(locations.count == 8)
        #expect(Set(locations.map(\.id)).count == 8)
        #expect(locations.first { $0.id == .notes }?.url.path == "/synthetic/current-library")
        #expect(locations.first { $0.id == .recordings }?.url.path == "/synthetic/current-library/.recordings")
        #expect(locations.first { $0.id == .drafts }?.url.path == "/synthetic/current-drafts")
        #expect(locations.first { $0.id == .searchCache }?.url.lastPathComponent == "chunks.json")
        #expect(locations.first { $0.id == .eventLog }?.url == NookEventLog.url)
        #expect(locations.filter { $0.scope == .directoryTree }.map(\.id) == [.appCache])
    }

    private func scan(_ location: StorageInventoryLocation) -> [StorageInventoryEntry] {
        StorageInventoryScanner.scan([location], cancellation: StorageInventoryCancellation())
    }
}

@MainActor
struct StorageInventoryControllerTests {
    @Test
    func theInitialOverviewAndAnEmptySuccessfulScanAreNotCalledCancelled() async throws {
        let controller = StorageInventoryController { _, _ in [] }
        #expect(controller.phase == .idle)
        #expect(controller.phase.label == "Ready to count file sizes")
        controller.refresh([])
        try await waitUntil { !controller.isScanning }
        #expect(controller.phase == .complete)
        #expect(controller.phase.label == "Current storage snapshot")
        controller.prepareForPresentation()
        #expect(controller.phase == .idle)
        #expect(controller.entries.isEmpty)
    }

    @Test
    func reopeningTheOverviewReusesItsWorkerAndReplacesOnlyPendingWork() async throws {
        let gate = InventoryScanGate()
        let calls = Mutex<[String]>([])
        let controller = StorageInventoryController { locations, _ in
            let name = locations[0].url.lastPathComponent
            calls.withLock { $0.append(name) }
            if name == "first" { gate.enter() }
            return [StorageInventoryEntry(location: locations[0], fileCount: 1, bytes: 10)]
        }
        controller.prepareForPresentation()
        controller.refresh([location("first")])
        try await gate.waitUntilEntered()
        for index in 0..<4 {
            controller.cancel()
            #expect(controller.phase == .cancelled)
            controller.prepareForPresentation()
            #expect(controller.phase == .idle)
            controller.refresh([location("reopened-\(index)")])
        }
        #expect(calls.withLock { $0 } == ["first"])
        gate.release()
        try await waitUntil { !controller.isScanning }
        #expect(calls.withLock { $0 } == ["first", "reopened-3"])
        #expect(controller.entries.first?.location.url.lastPathComponent == "reopened-3")
        #expect(controller.phase == .complete)
    }

    @Test
    func rapidRefreshesKeepOneActiveScanAndOnlyTheLatestPendingLocation() async throws {
        let gate = InventoryScanGate()
        let calls = Mutex<[String]>([])
        let controller = StorageInventoryController { locations, _ in
            #expect(!Thread.isMainThread)
            let name = locations[0].url.lastPathComponent
            calls.withLock { $0.append(name) }
            if name == "first" { gate.enter() }
            return [StorageInventoryEntry(location: locations[0], fileCount: 1, bytes: 10)]
        }
        controller.refresh([location("first")])
        try await gate.waitUntilEntered()
        controller.refresh([location("obsolete")])
        controller.refresh([location("latest")])
        #expect(controller.entries.isEmpty)
        #expect(controller.isScanning)
        gate.release()
        try await waitUntil { !controller.isScanning }
        #expect(controller.entries.first?.location.url.lastPathComponent == "latest")
        #expect(calls.withLock { $0 } == ["first", "latest"])
    }

    @Test
    func closingTheOverviewCancelsItsPendingPublicationEvenIfTheScannerIgnoresCancellation() async throws {
        let gate = InventoryScanGate()
        let finished = Mutex(false)
        let controller = StorageInventoryController { locations, _ in
            gate.enter()
            finished.withLock { $0 = true }
            return [StorageInventoryEntry(location: locations[0], fileCount: 7, bytes: 70)]
        }
        controller.refresh([location("cancelled")])
        try await gate.waitUntilEntered()
        controller.cancel()
        #expect(!controller.isScanning)
        gate.release()
        try await waitUntil { finished.withLock { $0 } }
        #expect(controller.entries.isEmpty)
    }

    @Test
    func releasingTheOverviewDoesNotKeepItsControllerAliveThroughAStalledScan() async throws {
        let gate = InventoryScanGate()
        var controller: StorageInventoryController? = StorageInventoryController { _, _ in
            gate.enter()
            return []
        }
        let weakController = WeakInventoryReference(controller)
        controller?.refresh([location("temporary")])
        try await gate.waitUntilEntered()
        controller = nil
        #expect(weakController.value == nil)
        gate.release()
    }

    private func location(_ name: String) -> StorageInventoryLocation {
        StorageInventoryLocation(id: .notes, url: URL(fileURLWithPath: "/synthetic/\(name)"), scope: .markdownFiles)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw InventoryFixtureError.waitTimedOut
    }
}

@MainActor
private final class WeakInventoryReference {
    weak var value: StorageInventoryController?
    init(_ value: StorageInventoryController?) { self.value = value }
}

private struct InventoryFixture {
    let root: URL

    init() throws {
        // Foundation's resolvingSymlinksInPath() aliases /private/var back to
        // /var on macOS. Resolve only this owned fixture base using realpath;
        // production inventory must never resolve a user-supplied linked path.
        guard let physical = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw InventoryFixtureError.temporaryDirectoryUnavailable
        }
        defer { free(physical) }
        root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent("NookStorageInventory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    func url(_ name: String) -> URL { root.appendingPathComponent(name) }
    func directory(_ name: String) throws {
        try FileManager.default.createDirectory(at: url(name), withIntermediateDirectories: true)
    }
    func file(_ name: String, bytes: Int, mode: Int = 0o600) throws {
        try Data(repeating: 0xFF, count: bytes).write(to: url(name))
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url(name).path)
    }
    func location(_ kind: StorageInventoryLocation.Kind, scope: StorageInventoryLocation.Scope) -> StorageInventoryLocation {
        StorageInventoryLocation(id: kind, url: root, scope: scope)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class InventoryScanGate: Sendable {
    private let entered = Mutex(false)
    private let semaphore = DispatchSemaphore(value: 0)

    func enter() {
        entered.withLock { $0 = true }
        _ = semaphore.wait(timeout: .now() + 5)
    }
    func release() { semaphore.signal() }
    func waitUntilEntered() async throws {
        for _ in 0..<200 {
            if entered.withLock({ $0 }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw InventoryFixtureError.waitTimedOut
    }
}

private enum InventoryFixtureError: Error { case waitTimedOut, temporaryDirectoryUnavailable }
