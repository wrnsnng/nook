import AppIntents

struct StartNookRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a Nook Recording"
    static let description = IntentDescription(
        "Starts a private local meeting recording in Nook."
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let meeting = AppModel.shared.meeting
        guard !meeting.phase.isRecording else {
            return .result(dialog: "Nook is already recording.")
        }
        meeting.startManualMeeting()
        return .result(dialog: "Nook is ready to record.")
    }
}

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
        guard let latest = model.store.notes.first else {
            model.openLibrary()
            return .result(dialog: "Your Nook library is empty.")
        }
        model.openLibrary(noteID: latest.id)
        return .result(dialog: "Opening \(latest.title).")
    }
}

struct NookShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartNookRecordingIntent(),
            phrases: [
                "Start a meeting with \(.applicationName)",
                "Record this meeting with \(.applicationName)",
            ],
            shortTitle: "Start Recording",
            systemImageName: "waveform.badge.mic"
        )

        AppShortcut(
            intent: OpenNookLibraryIntent(),
            phrases: [
                "Open my \(.applicationName) library",
            ],
            shortTitle: "Open Library",
            systemImageName: "books.vertical"
        )

        AppShortcut(
            intent: OpenLatestNookMeetingIntent(),
            phrases: [
                "Open my latest \(.applicationName) meeting",
            ],
            shortTitle: "Latest Meeting",
            systemImageName: "clock.arrow.circlepath"
        )
    }
}
