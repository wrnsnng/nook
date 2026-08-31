import CryptoKit
import Foundation
import FoundationModels
import NaturalLanguage

/// One searchable passage from a note, with enough provenance to cite it.
struct LibraryChunk: Hashable, Sendable {
    let noteID: UUID
    let noteTitle: String
    let startedAt: Date
    /// What kind of passage this is, e.g. "Summary" or "Decision".
    let label: String
    let text: String

    var embeddedText: String { "\(label): \(text)" }
}

struct LibraryCitation: Identifiable, Hashable, Sendable {
    let number: Int
    let chunk: LibraryChunk

    var id: Int { number }

    var displayTitle: String {
        "\(chunk.noteTitle), \(chunk.startedAt.formatted(date: .abbreviated, time: .omitted))"
    }
}

struct LibraryAnswer: Sendable {
    let text: String
    let citations: [LibraryCitation]
    /// Set when nothing matched well enough to answer at all.
    let refusedReason: String?
}

/// Turns a question into an answer grounded in the user's own notes.
///
/// Everything happens on this Mac: passages are embedded locally, ranked
/// locally, and the on-device model is only ever shown the few passages that
/// matched. The answer must cite its excerpts by number; anything that looks
/// invented is stripped before the user sees it, and a weak match is refused
/// outright rather than answered confidently.
@MainActor
final class LibraryAnswerService: ObservableObject {
    protocol TextEmbeddingProvider: Sendable {
        func vector(for text: String) -> [Double]?
    }

    struct NaturalLanguageEmbedding: TextEmbeddingProvider {
        func vector(for text: String) -> [Double]? {
            Self.sharedModel?.vector(for: text)
        }

        // `NLEmbedding.sentenceEmbedding` loads a multi-megabyte on-device
        // model from disk; building one per ranked chunk made every question
        // pay that cost hundreds of times over. The model is immutable once
        // constructed and Apple documents `vector(for:)` as safe to call
        // concurrently, so a process-lifetime singleton is safe to share
        // across the detached ranking task.
        nonisolated(unsafe) private static let sharedModel: NLEmbedding? =
            NLEmbedding.sentenceEmbedding(for: .english)
    }

    static let minimumMatchScore = 0.30
    static let maximumExcerpts = 6

    @Published private(set) var isPreparing = false
    @Published private(set) var lastError: String?

    private let embedding: any TextEmbeddingProvider
    private let cacheURL: URL

    init(
        embedding: any TextEmbeddingProvider =
            NaturalLanguageEmbedding(),
        cacheURL: URL? = nil
    ) {
        self.embedding = embedding
        self.cacheURL = cacheURL ?? Self.defaultCacheURL()
    }

    static func defaultCacheURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("NookAsk", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        // Derived data about the library lives here, never beside the notes
        // themselves, so the notes folder stays exactly what the user chose.
        return directory.appendingPathComponent("chunks.json")
    }

    // MARK: - Answering

    func answer(
        question: String,
        notes: [MeetingNote]
    ) async -> LibraryAnswer {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return LibraryAnswer(text: "", citations: [], refusedReason: "")
        }

        isPreparing = true
        defer { isPreparing = false }

        do {
            // Chunking walks every note's transcript and splits it into
            // passages; for a large library that is real work, so it runs
            // inside the detached task rather than blocking the main actor
            // before this function's first await.
            let ranking = Task.detached(priority: .userInitiated) {
                () async throws -> (Bool, [RankedChunk]) in
                let chunks = Self.chunks(from: notes)
                guard !chunks.isEmpty else { return (true, []) }
                return (
                    false,
                    try await Self.rank(
                        question: trimmed,
                        among: chunks,
                        embedding: self.embedding,
                        cacheURL: self.cacheURL
                    )
                )
            }
            // A detached task inherits nothing, cancellation included, so the
            // `Task.isCancelled` checks inside ranking were dead code and every
            // abandoned question embedded the whole library anyway. Bridging
            // the two makes them live: typing a new question now stops the old
            // one instead of racing it.
            let outcome = try await withTaskCancellationHandler {
                try await ranking.value
            } onCancel: {
                ranking.cancel()
            }

            let (libraryIsEmpty, ranked) = outcome
            guard !libraryIsEmpty else {
                return LibraryAnswer(
                    text: "",
                    citations: [],
                    refusedReason: LibraryNoteAggregation.partition(notes).omitted.isEmpty
                        ? "There are no notes to search yet."
                        : "No notes can be searched until the copies with a shared ID are reviewed."
                )
            }

            guard let best = ranked.first, best.score >= Self.minimumMatchScore
            else {
                return LibraryAnswer(
                    text: "",
                    citations: [],
                    refusedReason: """
                        Nothing in your notes matches that closely \
                        enough to answer.
                        """
                )
            }

            // The model pass is the expensive half, and nobody is waiting for
            // an answer to a question that has already been replaced.
            guard !Task.isCancelled else { return Self.abandoned }

            let excerpts = Array(ranked.prefix(Self.maximumExcerpts))
            return await Self.compose(
                question: trimmed,
                excerpts: excerpts
            )
        } catch is CancellationError {
            // Abandoning a question is the user changing their mind, not a
            // failure to put in front of them.
            return Self.abandoned
        } catch {
            lastError = error.localizedDescription
            return LibraryAnswer(
                text: "",
                citations: [],
                refusedReason: "Searching your notes failed this time."
            )
        }
    }

    /// What an abandoned question returns. The caller that started it has
    /// already stopped listening, so this is never displayed.
    private static let abandoned = LibraryAnswer(
        text: "",
        citations: [],
        refusedReason: nil
    )

    /// Grounds the answer in the numbered excerpts through the on-device
    /// model, falling back to showing the passages themselves if the model is
    /// unavailable. The user's words are never better served by a confident
    /// guess than by the real passages.
    private static func compose(
        question: String,
        excerpts: [RankedChunk]
    ) async -> LibraryAnswer {
        let citations = excerpts.enumerated().map { index, ranked in
            LibraryCitation(number: index + 1, chunk: ranked.chunk)
        }
        let listing = excerpts.enumerated()
            .map { index, ranked in
                "[\(index + 1)] (\(ranked.chunk.label)) \(ranked.chunk.text)"
            }
            .joined(separator: "\n\n")

        let instructions = """
            You answer questions about the user's own meeting notes. Use \
            only the numbered excerpts provided. After every claim, cite the \
            excerpt you used in square brackets, like [1] or [2]. If the \
            excerpts do not contain the answer, reply with exactly \
            NOT_IN_NOTES and nothing else.
            """

        do {
            let session = LanguageModelSession(
                instructions: Instructions(instructions)
            )
            let response = try await session.respond(
                to: """
                Excerpts:

                \(listing)

                Question: \(question)
                """
            )
            let text = response.content.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if text == "NOT_IN_NOTES" {
                return LibraryAnswer(
                    text: "",
                    citations: [],
                    refusedReason: """
                        Your notes do not seem to cover that. Try different \
                        words, or record more meetings about it.
                        """
                )
            }
            return LibraryAnswer(
                text: Self.sanitisingCitations(text, maximum: excerpts.count),
                citations: citations,
                refusedReason: nil
            )
        } catch let error as LanguageModelSession.GenerationError {
            // Distinct from the model being unavailable: retrieval matched
            // real passages, but their combined length overran the model's
            // context window. Telling the user to narrow the question is
            // actionable in a way "model unavailable" is not.
            guard case .exceededContextWindowSize = error else {
                return Self.unavailableFallback(citations: citations)
            }
            return LibraryAnswer(
                text: "",
                citations: [],
                refusedReason: """
                    That matched too much text for the on-device model to \
                    read at once. Try a narrower question.
                    """
            )
        } catch {
            return Self.unavailableFallback(citations: citations)
        }
    }

    private static func unavailableFallback(
        citations: [LibraryCitation]
    ) -> LibraryAnswer {
        // The model being unavailable must not lose the retrieval work: show
        // the passages themselves, honestly labelled.
        let passages = citations.map { citation in
            "[\(citation.number)] \(citation.chunk.label): \(citation.chunk.text)"
        }
        return LibraryAnswer(
            text: """
                The on-device model was unavailable, so here are the \
                closest passages instead:

                \(passages.joined(separator: "\n\n"))
                """,
            citations: citations,
            refusedReason: nil
        )
    }

    /// Removes citation markers pointing past the excerpts actually shown,
    /// which is how a model invents authority it does not have.
    static func sanitisingCitations(
        _ text: String,
        maximum: Int
    ) -> String {
        guard maximum > 0 else { return text }
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d+)\]"#)
        else { return text }

        let range = NSRange(text.startIndex..., in: text)
        var replacements: [(NSRange, String)] = []
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, let capture = Range(match.range(at: 1), in: text),
                  let number = Int(text[capture])
            else { return }
            if number < 1 || number > maximum {
                replacements.append((match.range, ""))
            }
        }

        var result = text
        for (range, replacement) in replacements.reversed() {
            guard let swiftRange = Range(range, in: result) else { continue }
            result.replaceSubrange(swiftRange, with: replacement)
        }
        return result
            .replacingOccurrences(of: "[ ]", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
    }

    // MARK: - Chunking

    /// Free-form prose (a summary or a paragraph of personal notes) can run
    /// to any length; every other label is inherently short. `compose()` can
    /// send up to `maximumExcerpts` chunks to the on-device model in one
    /// request, so six oversized excerpts here would be enough to overflow
    /// its context window on their own.
    nonisolated static let maximumFreeTextChunkCharacters = 1_500

    nonisolated private static func cappedForEmbedding(_ text: String) -> String {
        guard text.count > maximumFreeTextChunkCharacters else { return text }
        let cutoff = text.index(
            text.startIndex,
            offsetBy: maximumFreeTextChunkCharacters
        )
        var truncated = String(text[..<cutoff])
        if let lastSpace = truncated.lastIndex(of: " ") {
            truncated = String(truncated[..<lastSpace])
        }
        return truncated + "…"
    }

    /// Splits a note into labelled passages small enough to embed and cite.
    nonisolated static func chunks(from notes: [MeetingNote]) -> [LibraryChunk] {
        LibraryNoteAggregation.partition(notes).eligible.flatMap { note in
            var chunks: [LibraryChunk] = []

            func add(_ label: String, _ text: String) {
                let cleaned = text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !cleaned.isEmpty else { return }
                chunks.append(
                    LibraryChunk(
                        noteID: note.id,
                        noteTitle: note.title,
                        startedAt: note.startedAt,
                        label: label,
                        text: cleaned
                    )
                )
            }

            add("Summary", cappedForEmbedding(note.summary))
            note.keyPoints.forEach { add("Key point", $0) }
            note.decisions.forEach { add("Decision", $0) }
            note.actionItems.forEach { add("Action item", $0) }

            for paragraph in note.personalNotes.split(separator: "\n\n") {
                add("My notes", cappedForEmbedding(String(paragraph)))
            }

            addTranscript(of: note, into: &chunks)
            return chunks
        }
    }

    nonisolated private static func addTranscript(
        of note: MeetingNote,
        into chunks: inout [LibraryChunk]
    ) {
        var lines: [String] = []
        var length = 0

        func flush() {
            guard !lines.isEmpty else { return }
            chunks.append(
                LibraryChunk(
                    noteID: note.id,
                    noteTitle: note.title,
                    startedAt: note.startedAt,
                    label: "Discussion",
                    text: lines.joined(separator: "\n")
                )
            )
            lines.removeAll()
            length = 0
        }

        for segment in note.transcript {
            let line = "[\(segment.timestamp)] \(segment.source.label): \(segment.text)"
            length += line.count
            lines.append(line)
            if length > 600 {
                flush()
            }
        }
        flush()
    }
}

/// A passage scored against the question.
struct RankedChunk: Sendable {
    let chunk: LibraryChunk
    let score: Double
}

extension LibraryAnswerService {
    static func cosine(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot = 0.0
        var leftMagnitude = 0.0
        var rightMagnitude = 0.0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            leftMagnitude += lhs[index] * lhs[index]
            rightMagnitude += rhs[index] * rhs[index]
        }
        let denominator = (leftMagnitude * rightMagnitude).squareRoot()
        guard denominator > 0 else { return 0 }
        return dot / denominator
    }

    static func hash(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Ranks every chunk against the question, reusing vectors from an
    /// in-memory index that is loaded from disk once per process and
    /// written back at most once per question, pruned to the chunks that
    /// still exist. Earlier this reloaded and rewrote the whole on-disk
    /// cache unconditionally on every question, which never shrank as notes
    /// were edited or deleted.
    static func rank(
        question: String,
        among chunks: [LibraryChunk],
        embedding: any TextEmbeddingProvider,
        cacheURL: URL
    ) async throws -> [RankedChunk] {
        guard let questionVector = embedding.vector(for: question) else {
            throw LibraryAnswerError.embeddingsUnavailable
        }

        let store = await ChunkVectorStoreRegistry.shared.store(for: cacheURL)
        var results: [RankedChunk] = []
        var validHashes: Set<String> = []
        validHashes.reserveCapacity(chunks.count)

        for chunk in chunks {
            guard !Task.isCancelled else { break }

            let embeddedText = chunk.embeddedText
            let hash = Self.hash(of: embeddedText)
            validHashes.insert(hash)

            let vector: [Float]?
            if let cached = await store.vector(for: hash) {
                vector = cached
            } else if let fresh = embedding.vector(for: embeddedText) {
                let compact = fresh.map(Float.init)
                await store.set(compact, for: hash)
                vector = compact
            } else {
                vector = nil
            }
            guard let vector else { continue }
            results.append(
                RankedChunk(
                    chunk: chunk,
                    score: Self.cosine(questionVector, vector.map(Double.init))
                )
            )
        }

        // Chunks whose hash was not seen this question belong to notes that
        // were edited or deleted since the last question; drop them so the
        // cache does not grow forever.
        await store.prune(keeping: validHashes)
        // The cache is an optimisation. Failing to persist it must never
        // fail an answer; the next search simply embeds again.
        await store.persistIfNeeded()

        return results.sorted { $0.score > $1.score }
    }
}

enum LibraryAnswerError: LocalizedError {
    case embeddingsUnavailable

    var errorDescription: String? {
        switch self {
        case .embeddingsUnavailable:
            "On-device language assets for English are unavailable."
        }
    }
}

/// Passage hash to embedding vector, stored under Application Support.
///
/// Vectors are stored as `Float` rather than `Double`: sentence embeddings do
/// not need double precision, and halving each component roughly halves the
/// JSON file's size once a library has thousands of chunks.
typealias ChunkVectorCache = [String: [Float]]

extension ChunkVectorCache {
    static func load(from url: URL) throws -> ChunkVectorCache {
        let data = try Data(contentsOf: url)
        // A cache written by the previous `[String: [Double]]` format decodes
        // here without change, since JSON numeric literals decode into
        // `Float` just as readily; a genuinely unreadable file simply misses
        // the cache from then on rather than failing an answer.
        return try JSONDecoder().decode(ChunkVectorCache.self, from: data)
    }

    static func save(
        _ cache: ChunkVectorCache,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(cache).write(to: url, options: .atomic)
    }
}

/// One vector store per cache file, kept for the lifetime of the process so
/// that a second question in the same session never re-reads or re-embeds
/// what the first one already resolved.
actor ChunkVectorStoreRegistry {
    static let shared = ChunkVectorStoreRegistry()

    private var stores: [URL: ChunkVectorStore] = [:]

    func store(for url: URL) -> ChunkVectorStore {
        if let existing = stores[url] { return existing }
        let created = ChunkVectorStore(url: url)
        stores[url] = created
        return created
    }
}

/// In-memory index of chunk hash to embedding vector, backed by a single
/// on-disk file. Loaded lazily on first use and written only when dirty.
actor ChunkVectorStore {
    private let url: URL
    private var vectors: ChunkVectorCache = [:]
    private var isLoaded = false
    private var isDirty = false

    init(url: URL) {
        self.url = url
    }

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        vectors = (try? ChunkVectorCache.load(from: url)) ?? [:]
    }

    func vector(for hash: String) -> [Float]? {
        loadIfNeeded()
        return vectors[hash]
    }

    func set(_ vector: [Float], for hash: String) {
        loadIfNeeded()
        vectors[hash] = vector
        isDirty = true
    }

    /// Drops entries for chunks that no longer exist, so the file does not
    /// grow without bound as notes are edited or removed.
    func prune(keeping validHashes: Set<String>) {
        loadIfNeeded()
        let before = vectors.count
        vectors = vectors.filter { validHashes.contains($0.key) }
        if vectors.count != before {
            isDirty = true
        }
    }

    func persistIfNeeded() {
        guard isDirty else { return }
        isDirty = false
        try? ChunkVectorCache.save(vectors, to: url)
    }
}
