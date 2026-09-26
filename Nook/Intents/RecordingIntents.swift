import AppIntents

// Type names are what saved Shortcuts refer to. The recording actions that
// shipped before this folder existed keep theirs, so a Shortcut built on an
// earlier version keeps working; only their titles changed.

struct StartNookRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let description = IntentDescription(
        "Starts a private local meeting recording in Nook, exactly as the Record button does."
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let meeting = AppModel.shared.meeting
        try RecordingIntentRules.checkCanStart(meeting.phase)
        // The same entry point as every Record button, so permission prompts,
        // the pending-start resume after a permission restart, and the notch
        // presentation all behave identically.
        meeting.startManualMeeting()

        // Starting asks for permissions and prepares capture asynchronously.
        // Waiting briefly lets the reply say what actually happened. The wait
        // is bounded, so a permission prompt the user has not answered yet
        // cannot hold the Shortcut; that case replies "getting ready".
        for _ in 0..<50 {
            guard case .processing = meeting.phase else { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        switch RecordingIntentRules.startOutcome(after: meeting.phase) {
        case .recording:
            return .result(dialog: "Nook is recording.")
        case .preparing:
            return .result(dialog: "Nook is getting ready to record.")
        case .failed(let reason):
            throw NookIntentError.recordingFailed(reason)
        }
    }
}

struct FinishNookRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Finish Meeting"
    static let description = IntentDescription(
        "Stops recording and writes the meeting into a local note."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let meeting = AppModel.shared.meeting
        try RecordingIntentRules.checkIsRecording(meeting.phase)
        meeting.stopRecording()
        return .result(dialog: "Finishing the meeting. Nook is writing its note on this Mac.")
    }
}

/// Which way a pause request goes.
///
/// Spoken phrases say "pause" or "resume", and a plain toggle would answer
/// "pause" by resuming a recording that was already paused. Saved Shortcuts
/// from before this parameter existed keep toggling.
enum PauseRequest: String, AppEnum {
    case toggle
    case pause
    case resume

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Pause Action"
    static let caseDisplayRepresentations: [PauseRequest: DisplayRepresentation] = [
        .toggle: "Pause or Resume",
        .pause: "Pause",
        .resume: "Resume",
    ]
}

struct ToggleNookPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause or Resume Recording"
    static let description = IntentDescription(
        "Pauses the current Nook recording, or resumes it when it is paused."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Action", default: .toggle)
    var request: PauseRequest

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$request) the recording")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let meeting = AppModel.shared.meeting
        try RecordingIntentRules.checkCanTogglePause(
            meeting.phase,
            transitionInFlight: meeting.pauseTransitionInFlight
        )
        // Read before toggling. Pausing sets `isPaused` at once, so reading
        // it afterwards answered "Resuming" to a request that had just paused.
        let wasPaused = meeting.isPaused
        if let settled = RecordingIntentRules.alreadySettled(request, isPaused: wasPaused) {
            return .result(dialog: "\(settled)")
        }
        meeting.togglePause()
        return .result(dialog: "\(RecordingIntentRules.pauseDialog(wasPaused: wasPaused))")
    }
}

struct FlagNookMomentIntent: AppIntent {
    static let title: LocalizedStringResource = "Flag This Moment"
    static let description = IntentDescription(
        "Marks this point of the current recording so you can find it in the note."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let meeting = AppModel.shared.meeting
        try RecordingIntentRules.checkIsRecording(meeting.phase)
        meeting.flagMoment()
        guard let moment = meeting.liveMoments.last else {
            return .result(dialog: "Moment flagged.")
        }
        return .result(dialog: "Moment flagged at \(moment.timestamp).")
    }
}

struct TakeNookNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Take a Note"
    static let description = IntentDescription(
        "While recording, adds a line to My notes. Otherwise opens a quick note."
    )
    static let openAppWhenRun = false

    @Parameter(
        title: "Text",
        description: "The words to add. Leave empty to type them yourself."
    )
    var text: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Take a note \(\.$text)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        let meeting = model.meeting
        switch TakeNoteRoute.route(
            text: text,
            isRecording: meeting.phase.isRecording,
            liveNotes: meeting.liveNotes
        ) {
        case .addToMyNotes(let notes):
            // Assigning My notes is what typing does, so the line reaches the
            // recovery copy beside the recording on the same debounce.
            meeting.liveNotes = notes
            return .result(dialog: "Added to My notes.")
        case .askForNoteLine:
            meeting.requestNoteLine()
            return .result(dialog: "Type your note in the notch.")
        case .openQuickNote(let words):
            let pad = model.quickNote
            pad.present()
            guard let words else {
                return .result(dialog: "Quick note is open.")
            }
            pad.text = TakeNoteRoute.quickNoteText(adding: words, to: pad.text)
            // The pad's view schedules saves when its text changes, but a
            // pad that has only just been presented may not be observing yet.
            pad.scheduleSave()
            return .result(dialog: "Added to a quick note.")
        }
    }
}
