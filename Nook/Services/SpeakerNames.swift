import Foundation

/// Names for the separated voices on the meeting side of a transcript.
///
/// A name is only ever text in the note: it is written beside each line and
/// listed in the frontmatter, so the file reads correctly anywhere and no
/// voiceprint or model state outlives the separation that produced it.
enum SpeakerNames {
    /// "Speaker 1", "Speaker 2": what an unnamed voice is called until the
    /// user names it. One-based, in order of first appearance.
    static func placeholder(_ index: Int) -> String {
        "Speaker \(index + 1)"
    }

    static func isPlaceholder(_ name: String) -> Bool {
        name.range(of: #"^Speaker \d+$"#, options: .regularExpression) != nil
    }

    /// The labels the source column already uses. A person cannot be called
    /// either, or their lines would read back as the wrong source.
    private static let reserved: Set<String> = ["you", "meeting"]

    /// A name made safe to write: one line, no Markdown emphasis or colon
    /// that would break `**Name:**`, trimmed, and short enough for a column.
    /// Nil when nothing usable is left.
    static func sanitized(_ raw: String) -> String? {
        let cleaned = raw
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !reserved.contains(cleaned.lowercased()) else { return nil }
        return String(cleaned.prefix(40))
    }

    /// Every speaker in the transcript, in order of first appearance.
    static func speakers(in transcript: [TranscriptSegment]) -> [String] {
        var seen: [String] = []
        for segment in transcript {
            if let speaker = segment.speaker, !seen.contains(speaker) {
                seen.append(speaker)
            }
        }
        return seen
    }

    /// Labels meeting-side passages from a separation result: `assignments`
    /// maps a segment to a zero-based speaker in order of first appearance.
    /// The user's own passages are never relabelled, and a passage the
    /// separation could not place keeps "Meeting".
    static func apply(
        _ assignments: [UUID: Int],
        to transcript: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        transcript.map { segment in
            guard segment.source != .microphone, let index = assignments[segment.id] else {
                return segment
            }
            return segment.withSpeaker(placeholder(index))
        }
    }

    enum RenameResult: Equatable {
        case renamed([TranscriptSegment])
        /// The name was empty or reserved once cleaned.
        case invalidName
        /// Another speaker already has this name. Merging two voices is a
        /// different decision from naming one, so it is refused here.
        case nameInUse
    }

    /// Renames one speaker everywhere they spoke.
    static func rename(
        _ speaker: String,
        to rawName: String,
        in transcript: [TranscriptSegment]
    ) -> RenameResult {
        guard let name = sanitized(rawName) else { return .invalidName }
        if name == speaker { return .renamed(transcript) }
        guard !speakers(in: transcript).contains(name) else { return .nameInUse }
        return .renamed(transcript.map { segment in
            segment.speaker == speaker ? segment.withSpeaker(name) : segment
        })
    }
}
