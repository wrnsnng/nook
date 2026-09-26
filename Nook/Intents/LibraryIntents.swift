import AppIntents

struct OpenNookLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "Open the Nook Library"
    static let description = IntentDescription(
        "Opens your local meeting-note library."
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.openLibrary()
        return .result()
    }
}

struct OpenLatestNookMeetingIntent: AppIntent {
    static let title: LocalizedStringResource = "Open the Latest Nook Meeting"
    static let description = IntentDescription(
        "Opens your most recent local meeting note."
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        await waitForLibraryToLoad(model.store)
        guard let latest = model.store.notes.first else {
            model.openLibrary()
            return .result(dialog: "Your Nook library is empty.")
        }
        await openNoteWhenReady(latest.id, model: model)
        return .result(dialog: "Opening \(latest.title).")
    }
}

struct OpenNookMeetingIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Meeting"
    static let description = IntentDescription(
        "Opens a saved meeting or note in the Nook library."
    )
    static let openAppWhenRun = true

    @Parameter(title: "Meeting", requestValueDialog: "Which meeting?")
    var meeting: MeetingEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$meeting)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = AppModel.shared
        await waitForLibraryToLoad(model.store)
        // A Shortcut can hold on to a meeting long after its file was
        // trashed or copied. Saying so beats opening the library on a
        // "no longer in the selected folder" notice with no context.
        guard !MeetingEntityQuery.notes(withIDs: [meeting.id], in: model.store.notes).isEmpty
        else {
            throw NookIntentError.meetingUnavailable
        }
        await openNoteWhenReady(meeting.id, model: model)
        return .result()
    }
}

// Type name kept from the earlier "Get Latest Nook Note Text" action, which
// saved Shortcuts refer to.
struct LatestNookNoteTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Latest Meeting Summary"
    static let description = IntentDescription(
        "Returns the summary of your most recent Nook meeting."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let model = AppModel.shared
        await waitForLibraryToLoad(model.store)
        guard let latest = IntentLibrary.latestMeeting(in: model.store.notes) else {
            throw NookIntentError.noMeetings
        }
        let summary = try IntentLibrary.summary(of: latest)
        return .result(
            value: summary,
            dialog: "\(latest.title): \(summary)"
        )
    }
}

struct AskNookLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Your Library"
    static let description = IntentDescription(
        "Answers a question from your own meeting notes, entirely on this Mac, and names the meetings the answer came from."
    )
    static let openAppWhenRun = false

    @Parameter(
        title: "Question",
        requestValueDialog: "What would you like to ask your notes?"
    )
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask your library \(\.$question)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let model = AppModel.shared
        await waitForLibraryToLoad(model.store)
        // The same service the Ask sheet uses: the same local retrieval, the
        // same refusal of weak matches, and the same citation checks.
        let answer = await LibraryAnswerService().answer(
            question: question,
            notes: model.store.notes
        )
        let reply = try LibraryAskReply(answer)
        return .result(value: reply.text, dialog: "\(reply.spoken)")
    }
}

struct GetNookOpenActionItemsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Open Action Items"
    static let description = IntentDescription(
        "Returns every unchecked action item across your Nook notes, most urgent first."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let model = AppModel.shared
        await waitForLibraryToLoad(model.store)
        // Checkbox state lives in the files, not the decoded notes, so this
        // reads them the way the library's Open actions list does.
        let actions = OpenActionsController()
        await actions.refresh(store: model.store)
        let items = actions.entries.map(\.displayText)
        return .result(
            value: items,
            dialog: "\(IntentLibrary.openActionsDialog(items))"
        )
    }
}
