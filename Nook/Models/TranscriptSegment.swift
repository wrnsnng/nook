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

    var timestamp: String {
        let total = max(0, Int(startTime))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%02d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}

