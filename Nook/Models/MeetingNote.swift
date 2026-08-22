import Foundation

/// What a note in the library came from.
///
/// Both kinds are ordinary Markdown in the same folder, so search, editing, and
/// the raw view work identically. The distinction only changes how a note is
/// presented and which sections are meaningful for it.
enum NoteKind: String, Codable, Sendable {
    case meeting
    case spoken

    /// Notes written before this distinction existed are meetings.
    static let `default` = NoteKind.meeting

    var label: String {
        switch self {
        case .meeting: "Meeting"
        case .spoken: "Note"
        }
    }

    var symbol: String {
        switch self {
        case .meeting: "quote.bubble.fill"
        case .spoken: "waveform.badge.mic"
        }
    }
}

/// A moment the user flagged while the meeting was live.
///
/// Stored as an offset into the recording, so it stays meaningful whether or
/// not the audio was kept: against kept audio it is a playback position, and
/// against a transcript it marks where to read.
struct MeetingMoment: Hashable, Sendable {
    let offset: TimeInterval

    var timestamp: String {
        let total = max(0, Int(offset))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%02d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}

struct MeetingNote: Identifiable, Hashable, Sendable {
    let id: UUID
    var kind: NoteKind = .default
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
    /// Offsets the user flagged during the recording, in the order flagged.
    var moments: [MeetingMoment] = []
    var fileURL: URL?

    init(
        id: UUID = UUID(),
        kind: NoteKind = .default,
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
        moments: [MeetingMoment] = [],
        fileURL: URL? = nil
    ) {
        self.id = id
        self.kind = kind
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
        self.moments = moments
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
