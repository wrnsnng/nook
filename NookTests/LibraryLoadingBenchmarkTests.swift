import Darwin
import Foundation
import Testing
@testable import Nook

/// Opt-in, optimized measurements. Run each mode in a separate test
/// process so process high-water memory is not inherited from the other loader.
struct LibraryLoadingBenchmarkTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NOOK_LIBRARY_BENCHMARK"] != nil))
    func compareDiscoveryOpeningAndCompleteSearch() async throws {
        let mode = try #require(ProcessInfo.processInfo.environment["NOOK_LIBRARY_BENCHMARK"])
        #expect(["baseline", "metadata"].contains(mode))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Nook-Library-Benchmark-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        var totalBytes = 0
        var revisions = Data()
        // Alternating sources prevents the production assembler from coalescing
        // all 120 segments into a single row. All content is synthetic.
        let transcript = (0..<120).map { index in
            TranscriptSegment(startTime: Double(index * 10), duration: 9,
                text: "Synthetic discussion \(index) about release planning, explicit decisions, testing and follow-up. "
                    + String(repeating: "The team reviewed the proposed schedule and documented the outcome. ", count: 2)
                    + (index == 119 ? "uniquetranscriptneedle" : ""),
                source: index.isMultiple(of: 2) ? .system : .microphone)
        }
        for index in 0..<1_000 {
            let note = MeetingNote(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
                title: "Synthetic meeting \(index)",
                startedAt: date.addingTimeInterval(Double(index * 2_000)),
                endedAt: date.addingTimeInterval(Double(index * 2_000 + 1_200)),
                sourceApp: "Synthetic", summary: "Release planning summary",
                keyPoints: ["Verify the release"], decisions: ["Keep data local"],
                actionItems: ["Run acceptance checks"], personalNotes: "Keep this annotation",
                transcript: transcript)
            let data = autoreleasepool { Data(MarkdownCodec.encode(note).utf8) }
            totalBytes += data.count
            revisions.append(MeetingNote.contentRevision(data))
            try data.write(to: (index.isMultiple(of: 2) ? root : folder).appendingPathComponent("note-\(index).md"))
        }
        let longNote = MeetingNote(id: UUID(uuidString: "00000000-0000-0000-0000-000000001001")!,
            title: "Long transcript", startedAt: date.addingTimeInterval(3_000_000),
            endedAt: date.addingTimeInterval(3_100_000), sourceApp: "Synthetic", summary: "Long fixture",
            transcript: (0..<10_000).map { index in
                .init(startTime: Double(index * 10), duration: 9,
                      text: "Long synthetic transcript segment \(index). Preserve all these words.",
                      source: index.isMultiple(of: 2) ? .system : .microphone)
            })
        let longBytes = autoreleasepool { Data(MarkdownCodec.encode(longNote).utf8) }
        totalBytes += longBytes.count
        revisions.append(MeetingNote.contentRevision(longBytes))
        try longBytes.write(to: root.appendingPathComponent("long.md"))

        func measure<T>(_ operation: () throws -> T) rethrows -> (T, Double) {
            let start = ProcessInfo.processInfo.systemUptime
            let value = try autoreleasepool(invoking: operation)
            return (value, (ProcessInfo.processInfo.systemUptime - start) * 1_000)
        }
        func peakBytes() -> Int64 {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Int64(usage.ru_maxrss)
        }
        var samples: [[String: Double]] = []
        let fixturePeak = peakBytes()
        for _ in 0..<3 {
            var row: [String: Double] = [:]
            if mode == "baseline" {
                let cache = NoteDecodeCache()
                let (loaded, cold) = try measure { try MarkdownStore.loadNotes(in: root, cache: cache).get() }
                #expect(loaded.notes.count == 1_001 && loaded.issues.isEmpty)
                row["coldCatalogMs"] = cold
                row["catalogPeakBytes"] = Double(peakBytes())
                let (_, warm) = try measure { try MarkdownStore.loadNotes(in: root, cache: cache).get() }
                row["warmCatalogMs"] = warm
                let (opened, openTime) = measure { loaded.notes.first { $0.id == longNote.id } }
                #expect(opened?.transcript.count == 10_000)
                row["openLongNoteMs"] = openTime
                let documents = SearchDocumentCache()
                let start = ProcessInfo.processInfo.systemUptime
                let indexed = await documents.documents(for: loaded.notes)
                let hits = LibrarySearchController.matches(query: "uniquetranscriptneedle", notes: loaded.notes, documents: indexed)
                row["firstCompleteSearchMs"] = (ProcessInfo.processInfo.systemUptime - start) * 1_000
                #expect(hits.count == 1_000)
                let warmStart = ProcessInfo.processInfo.systemUptime
                let reused = await documents.documents(for: loaded.notes)
                #expect(LibrarySearchController.matches(query: "uniquetranscriptneedle", notes: loaded.notes, documents: reused).count == 1_000)
                row["repeatCompleteSearchMs"] = (ProcessInfo.processInfo.systemUptime - warmStart) * 1_000
            } else {
                var cache = LibraryLoadingSpike.Cache()
                let (catalog, cold) = try measure { try LibraryLoadingSpike.scan(root, cache: &cache) }
                #expect(catalog.entries.count == 1_001 && catalog.issues.isEmpty)
                row["coldCatalogMs"] = cold
                row["catalogPeakBytes"] = Double(peakBytes())
                let (_, warm) = try measure { try LibraryLoadingSpike.scan(root, cache: &cache) }
                row["warmCatalogMs"] = warm
                let entry = try #require(catalog.entries.first { $0.metadata.id == longNote.id })
                let (opened, openTime) = try measure { try LibraryLoadingSpike.load(entry) }
                #expect(opened.transcript.count == 10_000)
                row["openLongNoteMs"] = openTime
                var searchCache = LibraryLoadingSpike.SearchCache()
                let (hits, searchTime) = try measure { try LibraryLoadingSpike.search("uniquetranscriptneedle", catalog: catalog, cache: &searchCache) }
                #expect(hits.count == 1_000)
                row["firstCompleteSearchMs"] = searchTime
                let (again, repeatTime) = try measure { try LibraryLoadingSpike.search("uniquetranscriptneedle", catalog: catalog, cache: &searchCache) }
                #expect(again == hits)
                row["repeatCompleteSearchMs"] = repeatTime
            }
            row["processPeakBytes"] = Double(peakBytes())
            samples.append(row)
        }
        let output: [String: Any] = ["mode": mode, "noteCount": 1_001,
            "inputTranscriptSegments": 130_000, "markdownBytes": totalBytes,
            "fixtureRevision": MeetingNote.contentRevision(revisions).base64EncodedString(),
            "fixtureGenerationPeakBytes": fixturePeak, "samples": samples,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "coldDefinition": "Empty application cache; OS file cache not flushed",
            "memoryDefinition": "Process high-water RSS, including test host and fixture generation"]
        let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/library-benchmark-\(mode).json")
        try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]).write(to: destination)
        print("Library benchmark: \(destination.path)")
    }
}
