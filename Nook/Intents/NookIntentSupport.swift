import AppIntents
import Foundation

/// Why a Shortcuts or Siri action could not do what it was asked.
///
/// An action that quietly does nothing reads, from a Shortcut, exactly like
/// one that worked: the next step runs and the user finds out later. Every
/// case here is a sentence a person can act on, and a Shortcut stops on it.
enum NookIntentError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case alreadyRecording
    case busyWithRecording
    case notRecording
    case pauseChanging
    case recordingFailed(String)
    case noMeetings
    case noSummary(title: String)
    case meetingUnavailable
    case emptyQuestion
    case noAnswer(String)

    var message: String {
        switch self {
        case .alreadyRecording:
            "Nook is already recording."
        case .busyWithRecording:
            "Nook is still working on a recording. Try again when it has finished."
        case .notRecording:
            "Nook is not recording right now."
        case .pauseChanging:
            "Nook is still pausing or resuming. Try again in a moment."
        case .recordingFailed(let reason):
            reason
        case .noMeetings:
            "There are no meetings in your Nook library yet."
        case .noSummary(let title):
            "\u{201C}\(title)\u{201D} does not have a summary yet."
        case .meetingUnavailable:
            "That meeting is no longer in your notes folder."
        case .emptyQuestion:
            "Ask a question to search your notes."
        case .noAnswer(let reason):
            reason
        }
    }

    var localizedStringResource: LocalizedStringResource {
        "\(message)"
    }
}

/// Bounded wait for the library's initial load to finish.
///
/// Shortcuts can run an intent the instant the app launches, before
/// `MarkdownStore`'s first disk read completes; without this, "latest
/// meeting" intents answered from a still-empty `notes` array as if the
/// library genuinely held nothing. Bounded the same way the test suite
/// waits on a load: 100 checks, 20ms apart, so a load that never finishes
/// cannot hang an intent forever.
@MainActor
func waitForLibraryToLoad(_ store: MarkdownStore) async {
    for _ in 0..<100 where store.isLoading {
        try? await Task.sleep(for: .milliseconds(20))
    }
}

/// Opens the library at one note, once there is a library and a window to
/// show it in.
///
/// Spotlight and Shortcuts can both launch Nook to open a note. At that
/// moment the notes are still loading, so the library would report the note
/// as missing, and the SwiftUI window actions may not be installed yet, so
/// nothing would open at all. Both waits are bounded.
@MainActor
func openNoteWhenReady(_ id: MeetingNote.ID, model: AppModel = .shared) async {
    await waitForLibraryToLoad(model.store)
    for _ in 0..<100 where !model.canPresentWindows {
        try? await Task.sleep(for: .milliseconds(20))
    }
    model.openLibrary(noteID: id)
}

/// What the recording actions may do in each meeting phase.
///
/// The actions call the same coordinator methods as the Record, Pause and
/// Finish buttons, which already ignore a request that does not apply. These
/// checks exist so a Shortcut hears why instead of hearing nothing.
enum RecordingIntentRules {
    static func checkCanStart(_ phase: MeetingPhase) throws {
        switch phase {
        case .recording:
            throw NookIntentError.alreadyRecording
        case .processing:
            throw NookIntentError.busyWithRecording
        case .idle, .detected, .completed, .failed:
            return
        }
    }

    static func checkIsRecording(_ phase: MeetingPhase) throws {
        guard phase.isRecording else { throw NookIntentError.notRecording }
    }

    static func checkCanTogglePause(
        _ phase: MeetingPhase,
        transitionInFlight: Bool
    ) throws {
        try checkIsRecording(phase)
        // The coordinator drops a toggle while the previous one settles, so
        // saying "Paused" here would describe something that never happened.
        guard !transitionInFlight else { throw NookIntentError.pauseChanging }
    }

    enum StartOutcome: Equatable {
        case recording
        /// Still asking for permission or preparing capture.
        case preparing
        case failed(String)
    }

    /// What a start request has come to, read from the phase after it.
    static func startOutcome(after phase: MeetingPhase) -> StartOutcome {
        switch phase {
        case .recording:
            .recording
        case .failed(let reason):
            .failed(reason)
        case .idle, .detected, .processing, .completed:
            .preparing
        }
    }

    static func pauseDialog(wasPaused: Bool) -> String {
        wasPaused ? "Recording resumed." : "Recording paused."
    }

    /// The reply when the recording is already the way the request wants
    /// it, or nil when toggling is what the request asks for.
    ///
    /// Not an error: an automation that pauses Nook whenever the Mac locks
    /// should not stop with a failure because it was paused already.
    static func alreadySettled(_ request: PauseRequest, isPaused: Bool) -> String? {
        switch (request, isPaused) {
        case (.pause, true): "The recording is already paused."
        case (.resume, false): "The recording is not paused."
        default: nil
        }
    }
}

/// Where Take a Note sends its words.
///
/// While a meeting records, the note belongs in My notes, as its own bullet,
/// the same as a line typed into the notch. With nothing recording there are
/// no meeting notes to join, so the words start a quick note instead.
enum TakeNoteRoute: Equatable {
    /// My notes with the line added.
    case addToMyNotes(String)
    /// Recording, but nothing to add yet: ask the notch for a note line.
    case askForNoteLine
    /// Not recording: open the quick note pad, with these words when given.
    case openQuickNote(String?)

    static func route(
        text: String?,
        isRecording: Bool,
        liveNotes: String
    ) -> TakeNoteRoute {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard isRecording else {
            return .openQuickNote(trimmed.isEmpty ? nil : trimmed)
        }
        guard let notes = LiveNoteLine.appending(trimmed, to: liveNotes) else {
            return .askForNoteLine
        }
        return .addToMyNotes(notes)
    }

    /// The pad's text with `words` added on their own line, so a second
    /// Take a Note never runs into the end of the first.
    static func quickNoteText(adding words: String, to existing: String) -> String {
        guard !existing.isEmpty else { return words }
        let separator = existing.hasSuffix("\n") ? "" : "\n"
        return existing + separator + words
    }
}

/// Reading the library for actions that answer rather than open.
enum IntentLibrary {
    /// The most recent recorded meeting.
    ///
    /// Quick notes and digests are skipped: "latest meeting summary" means a
    /// meeting, and a digest is a summary of other notes. Copies sharing an
    /// ID are skipped for the same reason Ask skips them: Nook cannot tell
    /// which one is the meeting.
    static func latestMeeting(in notes: [MeetingNote]) -> MeetingNote? {
        LibraryNoteAggregation.partition(notes).eligible
            .filter { $0.kind == .meeting }
            .max { $0.startedAt < $1.startedAt }
    }

    static func summary(of note: MeetingNote) throws -> String {
        let summary = note.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            throw NookIntentError.noSummary(title: note.title)
        }
        return summary
    }

    /// How many open items a spoken reply reads out before summarising.
    static let spokenActionLimit = 5

    static func openActionsDialog(_ items: [String]) -> String {
        guard !items.isEmpty else { return "You have no open action items." }
        let heading = items.count == 1
            ? "You have 1 open action item:"
            : "You have \(items.count) open action items:"
        var lines = [heading] + items.prefix(spokenActionLimit).map { "\u{2022} \($0)" }
        let remaining = items.count - spokenActionLimit
        if remaining > 0 {
            lines.append("And \(remaining) more.")
        }
        return lines.joined(separator: "\n")
    }
}

/// What Ask Your Library hands back to a Shortcut and says out loud.
struct LibraryAskReply: Equatable {
    /// The answer with its citation numbers, followed by the numbered
    /// meetings they point to, so a Shortcut that saves it keeps the sources.
    let text: String
    /// The answer without citation numbers, which read badly aloud, and
    /// naming the meetings it came from.
    let spoken: String

    /// Refusals are thrown rather than returned. A refusal returned as the
    /// value would flow into the next step of a Shortcut as if it were an
    /// answer from the user's notes.
    init(_ answer: LibraryAnswer) throws {
        if let reason = answer.refusedReason {
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            throw trimmed.isEmpty
                ? NookIntentError.emptyQuestion
                : NookIntentError.noAnswer(trimmed)
        }
        let body = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            throw NookIntentError.noAnswer("Nook could not finish searching your notes. Try again.")
        }

        guard !answer.citations.isEmpty else {
            text = body
            spoken = Self.removingCitationMarkers(from: body)
            return
        }

        let sources = answer.citations.map { "[\($0.number)] \($0.displayTitle)" }
        text = body + "\n\nFrom your notes:\n" + sources.joined(separator: "\n")

        var seen: Set<String> = []
        let meetings = answer.citations
            .map(\.chunk.noteTitle)
            .filter { seen.insert($0).inserted }
            .map { "\u{201C}\($0)\u{201D}" }
        spoken = Self.removingCitationMarkers(from: body)
            + "\n\nFrom " + meetings.joined(separator: ", ") + "."
    }

    static func removingCitationMarkers(from text: String) -> String {
        text.replacingOccurrences(
            of: #"\s*\[\d+\]"#,
            with: "",
            options: .regularExpression
        )
    }
}
