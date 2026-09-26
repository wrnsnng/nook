import AppIntents

/// The actions Siri and Spotlight offer without the user building anything.
///
/// The system allows ten. Opening the library is left to the Shortcuts app
/// and the menu bar: every note-opening shortcut below opens the library
/// anyway, and a recording action is worth more to a voice.
struct NookShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .teal

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartNookRecordingIntent(),
            phrases: [
                "Start a recording in \(.applicationName)",
                "Start a meeting with \(.applicationName)",
                "Record this meeting with \(.applicationName)",
            ],
            shortTitle: "Start Recording",
            systemImageName: "waveform.badge.mic"
        )

        AppShortcut(
            intent: FinishNookRecordingIntent(),
            phrases: [
                "Finish the meeting in \(.applicationName)",
                "Stop recording in \(.applicationName)",
            ],
            shortTitle: "Finish Meeting",
            systemImageName: "stop.circle"
        )

        AppShortcut(
            intent: ToggleNookPauseIntent(),
            phrases: [
                "\(\.$request) the recording in \(.applicationName)",
                "\(\.$request) \(.applicationName)",
                "Pause or resume the recording in \(.applicationName)",
            ],
            shortTitle: "Pause or Resume",
            systemImageName: "playpause"
        )

        AppShortcut(
            intent: FlagNookMomentIntent(),
            phrases: [
                "Flag this moment in \(.applicationName)",
                "Mark this moment in \(.applicationName)",
            ],
            shortTitle: "Flag This Moment",
            systemImageName: "flag"
        )

        AppShortcut(
            intent: TakeNookNoteIntent(),
            phrases: [
                "Take a note in \(.applicationName)",
                "Add a note in \(.applicationName)",
            ],
            shortTitle: "Take a Note",
            systemImageName: "square.and.pencil"
        )

        AppShortcut(
            intent: AskNookLibraryIntent(),
            phrases: [
                "Ask \(.applicationName) a question",
                "Ask my \(.applicationName) library",
                "Search my meetings with \(.applicationName)",
            ],
            shortTitle: "Ask Your Library",
            systemImageName: "sparkle.magnifyingglass"
        )

        AppShortcut(
            intent: GetNookOpenActionItemsIntent(),
            phrases: [
                "What are my open action items in \(.applicationName)",
                "Get my open action items from \(.applicationName)",
            ],
            shortTitle: "Open Action Items",
            systemImageName: "checklist"
        )

        AppShortcut(
            intent: LatestNookNoteTextIntent(),
            phrases: [
                "Summarize my last meeting in \(.applicationName)",
                "Get my latest \(.applicationName) summary",
            ],
            shortTitle: "Latest Summary",
            systemImageName: "text.page.badge.magnifyingglass"
        )

        AppShortcut(
            intent: OpenNookMeetingIntent(),
            phrases: [
                "Open a meeting in \(.applicationName)",
                "Find a meeting in \(.applicationName)",
            ],
            shortTitle: "Open Meeting",
            systemImageName: "doc.text"
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
