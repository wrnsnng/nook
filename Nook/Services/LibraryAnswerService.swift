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
            guard let embedding = NLEmbedding.sentenceEmbedding(
                for: .english
            ) else { return nil }
            return embedding.vector(for: text)
        }
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

        let chunks = Self.chunks(from: notes)
        guard !chunks.isEmpty else {
            return LibraryAnswer(
                text: "",
                citations: [],
                refusedReason: "There are no notes to search yet."
            )
        }

        do {
            let ranked = try await Task.detached(priority: .userInitiated) {
                try await Self.rank(
                    question: trimmed,
                    among: chunks,
                    embedding: self.embedding,
                    cacheURL: self.cacheURL
                )
            }.value

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

            let excerpts = Array(ranked.prefix(Self.maximumExcerpts))
            return await Self.compose(
                question: trimmed,
                excerpts: excerpts
            )
        } catch {
            lastError = error.localizedDescription
            return LibraryAnswer(
                text: "",
                citations: [],
                refusedReason: "Searching your notes failed this time."
            )
        }
    }

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
        } catch {
            // The model being unavailable must not lose the retrieval work:
            // show the passages themselves, honestly labelled.
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

    /// Splits a note into labelled passages small enough to embed and cite.
    static func chunks(from notes: [MeetingNote]) -> [LibraryChunk] {
        notes.flatMap { note in
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

            add("Summary", note.summary)
            note.keyPoints.forEach { add("Key point", $0) }
            note.decisions.forEach { add("Decision", $0) }
            note.actionItems.forEach { add("Action item", $0) }

            for paragraph in note.personalNotes.split(separator: "\n\n") {
                add("My notes", String(paragraph))
            }

            addTranscript(of: note, into: &chunks)
            return chunks
        }
    }

    private static func addTranscript(
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

    /// Ranks every chunk against the question, reusing vectors from the
    /// on-disk cache where the passage text is unchanged.
    static func rank(
        question: String,
        among chunks: [LibraryChunk],
        embedding: any TextEmbeddingProvider,
        cacheURL: URL
    ) async throws -> [RankedChunk] {
        let cache = (try? ChunkVectorCache.load(from: cacheURL)) ?? [:]

        guard let questionVector = embedding.vector(for: question) else {
            throw LibraryAnswerError.embeddingsUnavailable
        }

        var results: [RankedChunk] = []
        var updated = cache
        for chunk in chunks {
            let embeddedText = chunk.embeddedText
            let hash = Self.hash(of: embeddedText)
            let vector: [Double]?
            if let cached = updated[hash] {
                vector = cached
            } else {
                vector = embedding.vector(for: embeddedText)
                if let vector {
                    updated[hash] = vector
                }
            }
            guard let vector else { continue }
            results.append(
                RankedChunk(
                    chunk: chunk,
                    score: Self.cosine(questionVector, vector)
                )
            )
        }

        // The cache is an optimisation. Failing to persist it must never
        // fail an answer; the next search simply embeds again.
        if updated != cache {
            try? ChunkVectorCache.save(updated, to: cacheURL)
        }
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
typealias ChunkVectorCache = [String: [Double]]

extension ChunkVectorCache {
    static func load(from url: URL) throws -> ChunkVectorCache {
        let data = try Data(contentsOf: url)
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
