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
}
