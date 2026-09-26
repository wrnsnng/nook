import Foundation

struct TranscriptSegment: Codable, Hashable, Identifiable, Sendable {
    enum Source: String, Codable, Sendable {
        case mixed
        case system
        case microphone
    }

    let id: UUID
    let startTime: TimeInterval
    let duration: TimeInterval
    let text: String
    let source: Source
    /// Who said a meeting-side passage, once speakers are separated: a
    /// name the user chose, or "Speaker 2" until they do. Nil for the
    /// user's own voice and for notes that were never separated.
    let speaker: String?

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        duration: TimeInterval,
        text: String,
        source: Source = .mixed,
        speaker: String? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.duration = duration
        self.text = text
        self.source = source
        self.speaker = speaker
    }

    /// The name a reader sees for this passage: the speaker when known,
    /// otherwise the source ("You", "Meeting").
    var speakerLabel: String {
        speaker ?? source.label
    }

    func withSpeaker(_ speaker: String?) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            startTime: startTime,
            duration: duration,
            text: text,
            source: source,
            speaker: speaker
        )
    }

    /// Where this segment starts, in the one stamp format Nook writes into a
    /// note's Markdown. Shared with `MeetingMoment` so a flagged moment and the
    /// line it points at cannot disagree about the same second.
    var timestamp: String {
        NookElapsedTime.stamp(startTime)
    }
}

