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
        NookElapsedTime.stamp(offset)
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

/// A piece of a note's file that Nook does not model, kept verbatim.
///
/// Encoding a note rebuilds the whole document from its fields, so anything
/// the format has no field for is deleted by the next save. People do put
/// their own `## Agenda` sections in these files, and a paragraph above a
/// list is ordinary writing. Carrying those bytes through the model is what
/// makes a rename or a personal-notes save non-destructive.
struct ExtraSection: Hashable, Sendable {
    /// The heading line exactly as written, or nil for loose lines that lived
    /// inside a section Nook models as a list.
    let heading: String?
    /// The lines under that heading, verbatim.
    let body: String
    /// The recognised heading this followed, lowercased as in
    /// `MarkdownCodec.recognizedHeadings`, or nil when it came before every
    /// recognised section. Encoding puts the block back after that heading's
    /// own content rather than dumping it at the end of the file.
    let anchor: String?
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
    /// The action items that are ticked, keyed by the exact stored text of the
    /// item, including any `[due: ...]` suffix.
    ///
    /// A parallel set rather than a richer item type: `actionItems` is read by
    /// search, the digest, the prep brief and the summary pipeline as plain
    /// strings, and every one of those stays correct while the completion bit
    /// travels beside it. Without it, `actionItems` had nowhere to carry
    /// "done", so every whole-note save re-encoded ticked items as `- [ ]` and
    /// a title rename silently reopened the user's finished tasks.
    ///
    /// Two items with identical text share one entry, so ticking one ticks
    /// both on the next whole-note save. Toggling goes through the line
    /// rewriter, which addresses items by position and is unaffected.
    var completedActionItems: Set<String> = []
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
    /// Sections and loose lines the file carries that no field models. Kept so
    /// re-encoding a hand-edited note cannot delete somebody's writing.
    var extraSections: [ExtraSection] = []
    var fileURL: URL?
    /// The file's modification date when this note was last read or written.
    ///
    /// The store compares it against the file before a whole-note save, so an
    /// edit made in another app between load and save is refused rather than
    /// overwritten from a model that predates it.
    var fileModified: Date?

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
        completedActionItems: Set<String> = [],
        personalNotes: String = "",
        transcript: [TranscriptSegment] = [],
        moments: [MeetingMoment] = [],
        sessions: [MeetingSession] = [],
        audioStart: TimeInterval = 0,
        extraSections: [ExtraSection] = [],
        fileURL: URL? = nil,
        fileModified: Date? = nil
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
        self.completedActionItems = completedActionItems
        self.personalNotes = personalNotes
        self.transcript = transcript
        self.moments = moments
        self.sessions = sessions
        self.audioStart = audioStart
        self.extraSections = extraSections
        self.fileURL = fileURL
        self.fileModified = fileModified
    }

    /// Whether this note carries nothing a reader would recognise as content.
    ///
    /// Used as a floor by the store: a save that would empty an existing file
    /// is a decode gap, not an edit.
    var hasNoContent: Bool {
        summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && keyPoints.isEmpty
            && decisions.isEmpty
            && actionItems.isEmpty
            && personalNotes.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
            && transcript.isEmpty
            && extraSections.isEmpty
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

    /// Never "0m": a note exists because a conversation was recorded, and a
    /// short one rounding to nothing reads as a failed recording.
    var durationLabel: String {
        NookElapsedTime.minutes(duration, atLeastAMinute: true)
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
