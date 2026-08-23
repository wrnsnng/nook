import AppIntents

/// Bounded wait for the library's initial load to finish.
///
/// Shortcuts can run an intent the instant the app launches, before
/// `MarkdownStore`'s first disk read completes; without this, "latest
/// meeting" intents answered from a still-empty `notes` array as if the
/// library genuinely held nothing. Bounded the same way the test suite
/// waits on a load: 100 checks, 20ms apart, so a load that never finishes
/// cannot hang an intent forever.
@MainActor
private func waitForLibraryToLoad(_ store: MarkdownStore) async {
    for _ in 0..<100 where store.isLoading {
        try? await Task.sleep(for: .milliseconds(20))
    }
}

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
        await waitForLibraryToLoad(model.store)
        guard let latest = model.store.notes.first else {
            model.openLibrary()
            return .result(dialog: "Your Nook library is empty.")
        }
        model.openLibrary(noteID: latest.id)
        return .result(dialog: "Opening \(latest.title).")
    }
}

struct FinishNookRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Finish a Nook Recording"
    static let description = IntentDescription(
        "Stops recording and processes the meeting into a local note."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let meeting = AppModel.shared.meeting
        guard meeting.phase.isRecording else {
            return .result(dialog: "Nook is not recording.")
        }
        meeting.stopRecording()
        return .result(dialog: "Finishing your note.")
    }
}

struct ToggleNookPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause or Resume a Nook Recording"
    static let description = IntentDescription(
        "Pauses or resumes the current Nook meeting recording."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let meeting = AppModel.shared.meeting
        guard meeting.phase.isRecording else {
            return .result(dialog: "Nook is not recording.")
        }
        meeting.togglePause()
        return .result(dialog: meeting.isPaused ? "Resuming." : "Paused.")
    }
}

struct LatestNookNoteTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Latest Nook Note Text"
    static let description = IntentDescription(
        "Returns the summary of your most recent Nook meeting note."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let model = AppModel.shared
        await waitForLibraryToLoad(model.store)
        guard let latest = model.store.notes.first else {
            return .result(value: "", dialog: "Your Nook library is empty.")
        }
        return .result(
            value: latest.summary,
            dialog: "Latest note: \(latest.title)."
        )
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
