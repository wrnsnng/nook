import Foundation

/// What a note in the library came from.
///
/// Both kinds are ordinary Markdown in the same folder, so search, editing, and
/// the raw view work identically. The distinction only changes how a note is
/// presented and which sections are meaningful for it.
enum NoteKind: String, Codable, Sendable {
    case meeting
    case spoken
    /// Compiled from several notes over a period, not recorded live.
    case digest

    /// Notes written before this distinction existed are meetings.
    static let `default` = NoteKind.meeting

    var label: String {
        switch self {
        case .meeting: "Meeting"
        case .spoken: "Note"
        case .digest: "Digest"
        }
    }

    var symbol: String {
        switch self {
        case .meeting: "quote.bubble.fill"
        case .spoken: "waveform.badge.mic"
        case .digest: "newspaper.fill"
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

/// One recorded sitting within a note.
///
/// A note usually has exactly one, which is why the field stays empty for
/// ordinary meetings: absent sessions means "read started and ended as one
/// sitting". A note gains several when a later recording is appended to it,
/// either by recording into the note again or by merging another note in.
struct MeetingSession: Hashable, Sendable {
    let startedAt: Date
    let endedAt: Date

    var duration: TimeInterval {
        max(0, endedAt.timeIntervalSince(startedAt))
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
    /// Recorded sittings beyond a single one, in order. Empty for every note
    /// with exactly one sitting.
    var sessions: [MeetingSession] = []
    /// Where kept audio begins on the transcript timeline.
    ///
    /// Normally zero: extraction concatenates every recording, so audio time
    /// and transcript time are one clock. It is positive only when material
    /// was appended after earlier audio was already gone, which leaves the
    /// kept file starting partway along the combined timeline.
    var audioStart: TimeInterval = 0
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
        sessions: [MeetingSession] = [],
        audioStart: TimeInterval = 0,
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
        self.sessions = sessions
        self.audioStart = audioStart
        self.fileURL = fileURL
    }

    var duration: TimeInterval {
        // A multi-session note's listening time is the sum of its sittings,
        // not the span that includes the lunch break between them.
        guard sessions.isEmpty else {
            return sessions.reduce(0) { $0 + $1.duration }
        }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }

    /// The furthest point the transcript reaches, which is also where
    /// appended material begins when there is no kept audio to measure.
    var transcriptExtent: TimeInterval {
        transcript.reduce(TimeInterval(0)) {
            max($0, $1.startTime + $1.duration)
        }
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
    /// Set when this recording was started from an existing note, so
    /// finalization appends to that note instead of creating a new one.
    let attachedNoteID: UUID?

    init(
        id: UUID,
        title: String,
        sourceApp: String,
        startedAt: Date,
        recordingURL: URL,
        attachedNoteID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.sourceApp = sourceApp
        self.startedAt = startedAt
        self.recordingURL = recordingURL
        self.attachedNoteID = attachedNoteID
    }
}
