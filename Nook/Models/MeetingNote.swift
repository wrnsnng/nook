import Foundation

struct MeetingNote: Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var startedAt: Date
    var endedAt: Date
    var sourceApp: String
    var summary: String
    var keyPoints: [String]
    var decisions: [String]
    var actionItems: [String]
    var personalNotes: String
    var transcript: [TranscriptSegment]
    var fileURL: URL?

    init(
        id: UUID = UUID(),
        title: String,
        startedAt: Date,
        endedAt: Date,
        sourceApp: String,
        summary: String,
        keyPoints: [String] = [],
        decisions: [String] = [],
        actionItems: [String] = [],
        personalNotes: String = "",
        transcript: [TranscriptSegment] = [],
        fileURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.sourceApp = sourceApp
        self.summary = summary
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.personalNotes = personalNotes
        self.transcript = transcript
        self.fileURL = fileURL
    }

    var duration: TimeInterval {
        max(0, endedAt.timeIntervalSince(startedAt))
    }

    var durationLabel: String {
        let minutes = max(1, Int(duration / 60))
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes)m"
    }

    var transcriptText: String {
        transcript.map(\.text).joined(separator: " ")
    }
}

struct MeetingDraft: Sendable {
    let id: UUID
    let title: String
    let sourceApp: String
    let startedAt: Date
    let recordingURL: URL
}
