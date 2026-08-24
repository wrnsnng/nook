import Foundation
import Testing
@testable import Nook

/// The retrieval layer must rank honestly, refuse weak matches instead of
/// guessing, and strip citation numbers the model was never given. These are
/// the trust properties of Ask your library, pinned with deterministic fake
/// embeddings so no language model participates.
@MainActor
struct LibraryAnswerTests {
    private func chunk(
        _ title: String,
        text: String,
        label: String = "Summary",
        startedAt: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> LibraryChunk {
        LibraryChunk(
            noteID: UUID(),
            noteTitle: title,
            startedAt: startedAt,
            label: label,
            text: text
        )
    }

    /// A tiny embedding world where every word maps to one dimension.
    private struct WordVectorEmbedding: LibraryAnswerService.TextEmbeddingProvider {
        func vector(for text: String) -> [Double]? {
            let words = Set(text.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init))
            var vector = [Double](repeating: 0, count: 8)
            let dimensions = [
                "pricing": 0, "migration": 1, "release": 2, "friday": 3,
                "design": 4, "review": 5, "onboarding": 6, "q3": 7
            ]
            for (word, dimension) in dimensions where words.contains(word) {
                vector[dimension] = 1
            }
            return vector.allSatisfy { $0 == 0 } ? nil : vector
        }
    }

    /// Counts every passage it is asked to embed, and takes long enough per
    /// passage that a cancellation lands partway through a large library.
    private final class CountingEmbedding:
        LibraryAnswerService.TextEmbeddingProvider, @unchecked Sendable
    {
        private let lock = NSLock()
        private var embedded = 0

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return embedded
        }

        func vector(for text: String) -> [Double]? {
            lock.lock()
            embedded += 1
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.005)
            return [1, 0]
        }
    }

    /// Abandoning a question has to stop the work it started, not merely
    /// ignore the answer. Ranking runs on a detached task, and a detached task
    /// inherits no cancellation, so every abandoned question used to embed the
    /// whole library and then run a full model pass nobody would read.
    @Test
    func abandoningAQuestionStopsTheWorkItStarted() async throws {
        let embedding = CountingEmbedding()
        let service = LibraryAnswerService(
            embedding: embedding,
            cacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("nook-ask-cancel-\(UUID().uuidString).json")
        )
        let notes = (0..<400).map { index in
            MeetingNote(
                title: "Meeting \(index)",
                startedAt: Date(timeIntervalSince1970: 1_780_000_000),
                endedAt: Date(timeIntervalSince1970: 1_780_003_600),
                sourceApp: "Zoom",
                summary: "Passage number \(index) about the pricing page."
            )
        }

        let asking = Task { await service.answer(question: "pricing", notes: notes) }
        try await Task.sleep(for: .milliseconds(120))
        asking.cancel()
        _ = await asking.value

        // Well short of the library: ranking stopped where it was told to.
        #expect(embedding.count < notes.count)
    }

    @Test
    func rankingPutsTheClosestPassageFirst() async throws {
        let chunks = [
            chunk("Design", text: "The design review covered onboarding flows"),
            chunk("Pricing", text: "We discussed pricing tiers and q3 revenue"),
            chunk("Release", text: "Ship the release on friday")
        ]

        let ranked = try await LibraryAnswerService.rank(
            question: "pricing q3",
            among: chunks,
            embedding: WordVectorEmbedding(),
            cacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("nook-ask-test-\(UUID().uuidString).json")
        )

        #expect(ranked.first?.chunk.noteTitle == "Pricing")
        #expect(ranked.count == 3)
        #expect(ranked[0].score > ranked[1].score)
    }

    @Test
    func aWeakMatchIsRefusedRatherThanAnswered() {
        // Covered through the threshold constant plus cosine math: a query
        // sharing nothing with any passage scores zero everywhere.
        let score = LibraryAnswerService.cosine(
            WordVectorEmbedding().vector(for: "pricing") ?? [],
            WordVectorEmbedding().vector(for: "design onboarding") ?? []
        )
        #expect(score == 0)
        #expect(score < LibraryAnswerService.minimumMatchScore)
    }

    @Test
    func citationsBeyondTheExcerptCountAreStripped() {
        let cleaned = LibraryAnswerService.sanitisingCitations(
            "Prices rise [1] next quarter [9] per the review [0].",
            maximum: 3
        )

        #expect(!cleaned.contains("[9]"))
        #expect(!cleaned.contains("[0]"))
        #expect(cleaned.contains("[1]"))
    }

    /// Passages come out labelled and attributed; transcript blocks stay
    /// bounded so hour-long meetings do not produce unembeddable walls of
    /// text.
    @Test
    func notesAreChunkedIntoLabelledPassages() {
        let longSpeech = (0..<80).map { index in
            TranscriptSegment(
                startTime: Double(index) * 30,
                duration: 20,
                text: "Sentence number \(index) about the release plan.",
                source: .system
            )
        }
        let note = MeetingNote(
            title: "Review",
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            endedAt: Date(timeIntervalSince1970: 1_003_600),
            sourceApp: "Zoom",
            summary: "The team reviewed pricing.",
            keyPoints: ["Tiers stay"],
            decisions: ["Hold until q3"],
            actionItems: ["Draft comparison"],
            personalNotes: "Ask about enterprise discount.\n\nFollow up Monday.",
            transcript: longSpeech
        )

        let chunks = LibraryAnswerService.chunks(from: [note])
        let labels = Dictionary(grouping: chunks, by: \.label)
            .mapValues(\.count)

        #expect(labels["Summary"] == 1)
        #expect(labels["Key point"] == 1)
        #expect(labels["Decision"] == 1)
        #expect(labels["Action item"] == 1)
        #expect(labels["My notes"] == 2)
        // 80 segments at ~45 characters each must split into several blocks.
        #expect((labels["Discussion"] ?? 0) > 3)
        #expect(chunks.allSatisfy { !$0.text.isEmpty })
    }

    /// A summary or personal-notes paragraph is free-form prose that can run
    /// to any length; six oversized excerpts of that kind sent to the
    /// on-device model in one request could overflow its context window on
    /// their own, so each is capped before it ever reaches embedding.
    @Test
    func summaryAndPersonalNotesChunksAreCappedForEmbedding() throws {
        let longText = String(repeating: "word ", count: 1_000)
        let note = MeetingNote(
            title: "Long meeting",
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            endedAt: Date(timeIntervalSince1970: 1_003_600),
            sourceApp: "Zoom",
            summary: longText,
            personalNotes: longText
        )

        let chunks = LibraryAnswerService.chunks(from: [note])
        let summaryChunk = chunks.first { $0.label == "Summary" }
        let notesChunk = chunks.first { $0.label == "My notes" }

        #expect(longText.count > LibraryAnswerService.maximumFreeTextChunkCharacters)
        let summaryCount = try #require(summaryChunk?.text.count)
        let notesCount = try #require(notesChunk?.text.count)
        #expect(summaryCount <= LibraryAnswerService.maximumFreeTextChunkCharacters)
        #expect(notesCount <= LibraryAnswerService.maximumFreeTextChunkCharacters)
        #expect(summaryChunk?.text.hasSuffix("…") == true)
    }

    /// Ranking used to reload and rewrite the whole on-disk vector cache on
    /// every question and never pruned it, so a library that had notes
    /// edited or deleted still carried their vectors forever. A question
    /// now leaves the cache holding only the chunks it was actually asked
    /// about.
    @Test
    func rankingPrunesVectorsForChunksThatNoLongerExist() async throws {
        let cacheURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nook-ask-test-\(UUID().uuidString).json")
        let design = chunk("Design", text: "The design review covered onboarding flows")
        let pricing = chunk("Pricing", text: "We discussed pricing tiers and q3 revenue")

        _ = try await LibraryAnswerService.rank(
            question: "pricing",
            among: [design, pricing],
            embedding: WordVectorEmbedding(),
            cacheURL: cacheURL
        )
        let afterFirstQuestion = try ChunkVectorCache.load(from: cacheURL)
        #expect(afterFirstQuestion.count == 2)

        // "Design" is no longer among the library's chunks, as if its note
        // had been edited or deleted since the last question.
        _ = try await LibraryAnswerService.rank(
            question: "pricing",
            among: [pricing],
            embedding: WordVectorEmbedding(),
            cacheURL: cacheURL
        )
        let afterSecondQuestion = try ChunkVectorCache.load(from: cacheURL)

        #expect(afterSecondQuestion.count == 1)
        #expect(
            afterSecondQuestion[LibraryAnswerService.hash(of: pricing.embeddedText)]
                != nil
        )
    }
}
