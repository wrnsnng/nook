import AppKit
import Combine
import CoreSpotlight
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Whether saved meetings appear in Spotlight. On until the user turns it off
/// in Settings, General.
enum SpotlightIndexPreference {
    static let key = "showMeetingsInSpotlight"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}

/// One saved note as Spotlight knows it.
///
/// Deliberately less than the note: the title, the summary, and the key
/// points and decisions as keywords. The transcript and My notes stay out.
/// The Markdown file itself is already searchable as a file wherever the
/// user keeps it, and Spotlight's copy of this app's items should be the
/// part a person would want to see in a search result, not every word said.
///
/// Digests are not indexed. A digest restates other notes, so each search
/// would return the meeting and then the digest quoting it, and opening the
/// digest leads away from the place the words were actually said.
struct MeetingSearchEntry: Equatable, Sendable {
    static let domain = "meetings"
    /// Part of every fingerprint, so a change to what is indexed reaches
    /// every item on the next sync without a manual rebuild.
    static let formatVersion = 1
    /// Enough to find a meeting by its main points without handing Spotlight
    /// a note's whole outline.
    static let keywordLimit = 30

    /// The note's Markdown UUID. It survives a rename that moves the file,
    /// and it is what the library resolves when a result is opened.
    let identifier: String
    let title: String
    let summary: String
    let keywords: [String]
    let startedAt: Date

    /// Nil for notes that do not belong in Spotlight: digests, and notes
    /// with no file yet.
    init?(note: MeetingNote) {
        guard note.kind != .digest, note.fileURL != nil else { return nil }
        identifier = note.id.uuidString
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title.isEmpty ? note.kind.label : title
        summary = note.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen: Set<String> = []
        keywords = (note.keyPoints + note.decisions)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.localizedLowercase).inserted }
            .prefix(Self.keywordLimit)
            .map { $0 }
        startedAt = note.startedAt
    }

    /// Every note that belongs in Spotlight.
    ///
    /// Copies sharing a UUID are left out until the user reviews them, as
    /// Ask and the digest leave them out: one identifier cannot name two
    /// files, and indexing either copy would hide the other.
    static func entries(for notes: [MeetingNote]) -> [MeetingSearchEntry] {
        LibraryNoteAggregation.partition(notes).eligible.compactMap(Self.init(note:))
    }

    /// A digest of exactly what is indexed, so a note is only sent again
    /// when something Spotlight holds has changed. Editing a transcript line
    /// or My notes changes the file but not this.
    var fingerprint: String {
        let fields = [
            "v\(Self.formatVersion)",
            identifier,
            title,
            summary,
            keywords.joined(separator: "\u{1F}"),
            String(startedAt.timeIntervalSinceReferenceDate),
        ]
        let digest = SHA256.hash(data: Data(fields.joined(separator: "\u{1E}").utf8))
        // Sixteen hex digits keep the on-disk record small for a library of
        // thousands of notes; a collision would at worst skip one refresh.
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    var attributes: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = title
        attributes.displayName = title
        attributes.contentDescription = summary.isEmpty ? nil : summary
        attributes.keywords = keywords.isEmpty ? nil : keywords
        attributes.contentCreationDate = startedAt
        return attributes
    }

    var searchableItem: CSSearchableItem {
        let item = CSSearchableItem(
            uniqueIdentifier: identifier,
            domainIdentifier: Self.domain,
            attributeSet: attributes
        )
        // Spotlight drops an item a month after it was indexed unless told
        // otherwise. A meeting that has not changed is not sent again, so
        // without this every untouched note would quietly vanish from search.
        item.expirationDate = .distantFuture
        return item
    }
}

/// What to send Spotlight to bring it from `indexed` to `desired`.
struct SpotlightIndexPlan: Equatable {
    var upserts: [MeetingSearchEntry]
    var removals: [String]

    var isEmpty: Bool { upserts.isEmpty && removals.isEmpty }

    init(desired: [MeetingSearchEntry], indexed: [String: String]) {
        upserts = desired.filter { indexed[$0.identifier] != $0.fingerprint }
        let wanted = Set(desired.map(\.identifier))
        removals = indexed.keys.filter { !wanted.contains($0) }.sorted()
    }
}

/// The three things Nook ever asks of Spotlight, separated so tests can
/// watch them without touching the user's real index.
struct SpotlightIndexClient: Sendable {
    var index: @Sendable ([MeetingSearchEntry]) async throws -> Void
    var remove: @Sendable ([String]) async throws -> Void
    var removeAll: @Sendable () async throws -> Void

    static let live = SpotlightIndexClient(
        index: { entries in
            try await CSSearchableIndex.default()
                .indexSearchableItems(entries.map(\.searchableItem))
        },
        remove: { identifiers in
            try await CSSearchableIndex.default()
                .deleteSearchableItems(withIdentifiers: identifiers)
        },
        removeAll: {
            try await CSSearchableIndex.default().deleteAllSearchableItems()
        }
    )
}

/// Keeps Spotlight's copy of the library in step with `MarkdownStore`.
///
/// Changes are coalesced and applied by one worker, so bursts of saves cost
/// one sync and two syncs never interleave. Each sync compares fingerprints
/// with a record of what Spotlight was last sent, so an unchanged library
/// sends nothing, including at launch, and a note trashed while Nook was
/// closed is still removed. The record lives in this installation's caches:
/// losing it costs one full rebuild, never a stale result.
@MainActor
final class MeetingSpotlightIndexer {
    /// Items per request, so a first sync of a large library does not hand
    /// Spotlight one enormous message.
    static let batchSize = 500

    private let client: SpotlightIndexClient
    private let recordURL: URL
    private let debounce: Duration
    private let wakeups: AsyncStream<Void>
    private let wake: AsyncStream<Void>.Continuation
    private var pending: (notes: [MeetingNote], enabled: Bool)?
    private var worker: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    /// Identifier to fingerprint for everything Spotlight holds, or nil
    /// before the on-disk record has been read.
    private var indexed: [String: String]?
    /// Whether Spotlight has been cleared since indexing was turned off, so
    /// every later library change while it stays off costs nothing.
    private var clearedWhileDisabled = false

    init(
        client: SpotlightIndexClient = .live,
        recordURL: URL = MeetingSpotlightIndexer.defaultRecordURL(),
        debounce: Duration = .seconds(2)
    ) {
        self.client = client
        self.recordURL = recordURL
        self.debounce = debounce
        (wakeups, wake) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    deinit {
        wake.finish()
    }

    /// Spotlight's index belongs to one bundle identifier, so the record of
    /// what was sent to it does too. A cache, because it can be rebuilt.
    nonisolated static func defaultRecordURL() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let identity = Bundle.main.bundleIdentifier ?? "com.localfirst.nook.dev"
        return caches
            .appendingPathComponent(identity, isDirectory: true)
            .appendingPathComponent("Spotlight", isDirectory: true)
            .appendingPathComponent("indexed-notes.json")
    }

    func observe(_ store: MarkdownStore, defaults: UserDefaults = .standard) {
        startWorker()
        let enabled = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification, object: defaults)
            // Defaults can change on any thread, and everything below is
            // main-actor code.
            .receive(on: DispatchQueue.main)
            .map { _ in SpotlightIndexPreference.isEnabled(in: defaults) }
            .prepend(SpotlightIndexPreference.isEnabled(in: defaults))
            .removeDuplicates()

        Publishers.CombineLatest3(store.$notes, store.$isLoading, enabled)
            .sink { [weak self] notes, isLoading, enabled in
                // A library mid-load looks empty. Syncing then would remove
                // every item only to add them back a moment later.
                guard !enabled || !isLoading else { return }
                self?.request(notes: notes, enabled: enabled)
            }
            .store(in: &cancellables)
    }

    private func request(notes: [MeetingNote], enabled: Bool) {
        pending = (notes, enabled)
        wake.yield()
    }

    private func startWorker() {
        guard worker == nil else { return }
        let wakeups = wakeups
        let debounce = debounce
        worker = Task { [weak self] in
            for await _ in wakeups {
                try? await Task.sleep(for: debounce)
                guard let self else { return }
                guard let job = self.pending else { continue }
                self.pending = nil
                await self.apply(notes: job.notes, enabled: job.enabled)
            }
        }
    }

    /// Brings Spotlight in line with `notes`, or empties it when indexing is
    /// off. A failed request is left for the next change to retry: only what
    /// Spotlight accepted is written to the record.
    func apply(notes: [MeetingNote], enabled: Bool) async {
        guard enabled else {
            await clear()
            return
        }
        clearedWhileDisabled = false

        let desired = await Task.detached(priority: .utility) {
            MeetingSearchEntry.entries(for: notes)
        }.value

        var current: [String: String]
        var recordChanged = false
        if let indexed {
            current = indexed
        } else if let record = await Self.readRecord(at: recordURL) {
            current = record
        } else {
            // Nothing says what an earlier run left in Spotlight: a first
            // launch, a cleared cache, or indexing just turned back on. Start
            // from empty so a note deleted meanwhile cannot linger.
            do {
                try await client.removeAll()
            } catch {
                NookEventLog.write(.spotlightIndexFailed)
                return
            }
            current = [:]
            recordChanged = true
        }

        let plan = SpotlightIndexPlan(desired: desired, indexed: current)
        if !plan.isEmpty {
            recordChanged = true
            do {
                if !plan.removals.isEmpty {
                    try await client.remove(plan.removals)
                    for identifier in plan.removals { current[identifier] = nil }
                }
                var start = plan.upserts.startIndex
                while start < plan.upserts.endIndex {
                    let end = min(start + Self.batchSize, plan.upserts.endIndex)
                    let batch = Array(plan.upserts[start..<end])
                    try await client.index(batch)
                    for entry in batch { current[entry.identifier] = entry.fingerprint }
                    start = end
                }
            } catch {
                NookEventLog.write(.spotlightIndexFailed)
            }
        }
        indexed = current
        if recordChanged {
            await Self.writeRecord(current, to: recordURL)
        }
    }

    private func clear() async {
        guard !clearedWhileDisabled else { return }
        do {
            try await client.removeAll()
        } catch {
            NookEventLog.write(.spotlightIndexFailed)
            return
        }
        clearedWhileDisabled = true
        indexed = nil
        await Self.removeRecord(at: recordURL)
    }

    private nonisolated static func readRecord(at url: URL) async -> [String: String]? {
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode([String: String].self, from: data)
        }.value
    }

    private nonisolated static func writeRecord(_ record: [String: String], to url: URL) async {
        await Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(record) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
        }.value
    }

    private nonisolated static func removeRecord(at url: URL) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }.value
    }
}

/// Opening a meeting from a Spotlight result.
@MainActor
enum MeetingSpotlightContinuation {
    static let activityType = CSSearchableItemActionType

    /// AppKit's delegate and SwiftUI can both be handed the same activity.
    /// Remembering it keeps one click from opening the note twice.
    private static weak var lastHandled: NSUserActivity?

    nonisolated static func noteID(from activity: NSUserActivity) -> UUID? {
        guard activity.activityType == CSSearchableItemActionType,
              let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
        else { return nil }
        return UUID(uuidString: identifier)
    }

    /// Opens the note a Spotlight result names. Returns false for any other
    /// activity so the caller can leave it to the system.
    @discardableResult
    static func open(_ activity: NSUserActivity) -> Bool {
        guard let id = noteID(from: activity) else { return false }
        guard activity !== lastHandled else { return true }
        lastHandled = activity
        Task { @MainActor in
            await openNoteWhenReady(id)
        }
        return true
    }
}
