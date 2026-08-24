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

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        duration: TimeInterval,
        text: String,
        source: Source = .mixed
    ) {
        self.id = id
        self.startTime = startTime
        self.duration = duration
        self.text = text
        self.source = source
    }

    /// Where this segment starts, in the one stamp format Nook writes into a
    /// note's Markdown. Shared with `MeetingMoment` so a flagged moment and the
    /// line it points at cannot disagree about the same second.
    var timestamp: String {
        NookElapsedTime.stamp(startTime)
    }
}

