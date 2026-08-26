import AppKit
import SwiftUI

@main
struct SnapshotRenderer {
    @MainActor
    static func main() throws {
        let arguments = CommandLine.arguments
        guard (2...3).contains(arguments.count) else {
            FileHandle.standardError.write(
                Data("Usage: NookSnapshot <output.png> [library|library-light|library-compact|welcome-light|welcome-dark|welcome-permission-light|welcome-permission-dark|welcome-ready-light|welcome-ready-dark|welcome-microphone-light|welcome-microphone-dark|welcome-speech-light|welcome-speech-dark|welcome-calendar-light|welcome-calendar-dark|welcome-dictation-light|welcome-dictation-dark|detail-transcript-light|detail-transcript-dark|detail-markdown-light|detail-markdown-dark|detail-notes-light|detail-notes-dark|settings-about-light|settings-about-dark|settings-general-light|settings-general-dark|settings-listening-light|settings-listening-dark|settings-dictation-light|settings-dictation-dark|settings-keyboard-light|settings-keyboard-dark|settings-privacy-light|settings-privacy-dark|settings-updates-light|settings-updates-dark|quick-note-light|quick-note-dark|quick-note-filled-light|quick-note-filled-dark|prep-light|prep-dark|ask-light|ask-dark|palette-light|palette-dark|floating-notes-light|floating-notes-dark|library-recording-light|library-recording-dark|live|notch|external-panel|summary-light|summary-dark|notes-light|notes-dark|detected-light|detected-dark|detected-compact-light|detected-compact-dark|processing-light|processing-dark|completed-light|completed-dark|failure-light|failure-dark]\n".utf8)
            )
            Foundation.exit(64)
        }
        let mode = arguments.count == 3 ? arguments[2] : "library"
        let snapshotColorScheme: ColorScheme = mode.hasSuffix("-light")
            ? .light
            : .dark

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iconURL = workspace
            .appendingPathComponent("Nook")
            .appendingPathComponent("Resources")
            .appendingPathComponent("Brand")
            .appendingPathComponent("NookIconSource-Cobalt.png")
        if let icon = NSImage(contentsOf: iconURL) {
            app.applicationIconImage = icon
        }

        let fileManager = FileManager.default
        let fixtureDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("NookSnapshot-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? fileManager.removeItem(at: fixtureDirectory)
        }

        let store = MarkdownStore()
        store.storageURL = fixtureDirectory
        let fixtures = fixtureNotes
        for note in fixtures {
            try store.save(note)
        }
        guard
            store.notes.count == fixtures.count,
            let roundTripped = store.notes.first(where: { $0.id == fixtures[0].id }),
            roundTripped.transcript.map(\.source) == [.system, .microphone]
        else {
            throw SnapshotError.fixtureValidationFailed
        }

        let detector = MeetingDetector()
        let meeting = MeetingCoordinator(store: store, detector: detector)
        let markdownDraft = MarkdownDraftController()
        let personalNotesDraft = PersonalNotesDraftController()
        let shortcutDefaultsName = "NookSnapshot-\(UUID().uuidString)"
        let shortcutDefaults = UserDefaults(suiteName: shortcutDefaultsName)
            ?? .standard
        shortcutDefaults.removePersistentDomain(forName: shortcutDefaultsName)
        let shortcuts = ShortcutStore(defaults: shortcutDefaults)
        defer {
            shortcutDefaults.removePersistentDomain(forName: shortcutDefaultsName)
        }
        let appearanceController = NookAppearanceController(
            initialSelection: snapshotColorScheme == .light ? .light : .dark,
            persistsSelection: false
        )
        let updateController = NookUpdateController(startingUpdater: false)
        let calendar = CalendarContextService(provider: SnapshotCalendarProvider())
        calendar.onUpcomingEvent = { _ in }
        let prep = PrepBriefController(store: store, calendar: calendar)
        let dictation = DictationCoordinator(localeIdentifier: "en_US", registersShortcut: false)
        let quickNote = QuickNoteController(store: store)
        let recovery = RecordingRecovery(store: store)
        let audioInputCheck = AudioInputCheckService()
        if mode.contains("prep") || mode.contains("library") {
            Task { @MainActor in await calendar.setEnabled(true) }
        }
        let transcriptState = LiveTranscriptState(
            segments: [
                TranscriptSegment(
                    startTime: 32,
                    duration: 6,
                    text: "The strongest version feels present without asking people to manage another window.",
                    source: .system
                ),
                TranscriptSegment(
                    startTime: 41,
                    duration: 7,
                    text: "Exactly. The notch can hold the live moment, and the library can stay calm.",
                    source: .microphone
                ),
                TranscriptSegment(
                    startTime: 52,
                    duration: 8,
                    text: "Let’s keep the animation restrained and make the words the most important thing.",
                    source: .system
                )
            ],
            meetingPartial: "The live captions should feel immediate, almost like",
            microphonePartial: "",
            latestSource: .system,
            revision: 12
        )
        let canvasSize: CGSize
        let content: AnyView
        switch mode {
        case _ where mode.hasPrefix("welcome"):
            canvasSize = CGSize(width: 680, height: 560)
            let welcomeStep: WelcomeStep
            if mode.contains("permission") || mode.contains("screen") { welcomeStep = .screenRecording }
            else if mode.contains("ready") { welcomeStep = .ready }
            else if mode.contains("microphone") { welcomeStep = .microphone }
            else if mode.contains("speech") { welcomeStep = .speechRecognition }
            else if mode.contains("calendar") { welcomeStep = .calendar }
            else if mode.contains("dictation") { welcomeStep = .dictation }
            else { welcomeStep = .introduction }
            content = AnyView(
                WelcomeView(detector: detector, initialStep: welcomeStep)
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .environment(\.colorScheme, snapshotColorScheme)
                    .transaction { $0.disablesAnimations = true }
            )
        case _ where mode.hasPrefix("detail"):
            canvasSize = CGSize(width: 1_100, height: 700)
            let initialTab: DetailTab = mode.contains("transcript")
                ? .transcript
                : (mode.contains("markdown") ? .markdown : .notes)
            meeting.setPreviewState(phase: .idle, elapsed: 0, liveTranscript: .empty, audioLevel: 0)
            content = AnyView(
                MeetingDetailView(
                    note: roundTripped,
                    initialTab: initialTab
                )
                .environmentObject(store)
                .environmentObject(meeting)
                .environmentObject(markdownDraft)
                .environmentObject(personalNotesDraft)
                .frame(width: canvasSize.width, height: canvasSize.height)
                .environment(\.colorScheme, snapshotColorScheme)
                .transaction { $0.disablesAnimations = true }
            )
        case _ where mode.hasPrefix("settings"):
            canvasSize = CGSize(width: 620, height: 540)
            let pane: SettingsPane
            if mode.contains("about") { pane = .about }
            else if mode.contains("dictation") { pane = .dictation }
            else if mode.contains("keyboard") { pane = .keyboard }
            else if mode.contains("privacy") { pane = .privacy }
            else if mode.contains("updates") { pane = .updates }
            else if mode.contains("listening") { pane = .listening }
            else { pane = .general }
            meeting.setPreviewState(phase: .idle, elapsed: 0, liveTranscript: .empty, audioLevel: 0)
            content = AnyView(
                SettingsView(initialPane: pane)
                    .environmentObject(store)
                    .environmentObject(detector)
                    .environmentObject(meeting)
                    .environmentObject(appearanceController)
                    .environmentObject(updateController)
                    .environmentObject(dictation)
                    .environmentObject(quickNote)
                    .environmentObject(audioInputCheck)
                    .environmentObject(calendar)
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, snapshotColorScheme)
                    .transaction { $0.disablesAnimations = true }
            )
        case "quick-note-light", "quick-note-dark", "quick-note-filled-light", "quick-note-filled-dark":
            canvasSize = CGSize(width: 460, height: 340)
            if mode.hasPrefix("quick-note-filled") {
                quickNote.text = "Call Priya about the vendor contract by Thursday.\nShe wants the revised scope before the board meeting.\n\n- [ ] Send the scope doc"
            }
            content = AnyView(
                QuickNoteView()
                    .environmentObject(quickNote)
                    .environmentObject(dictation)
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .environment(\.colorScheme, snapshotColorScheme)
                    .transaction { $0.disablesAnimations = true }
            )
        case "prep-light", "prep-dark":
            canvasSize = CGSize(width: 1_100, height: 700)
            let brief = PrepBriefBuilder.build(
                eventTitle: "Research synthesis",
                startDate: Date().addingTimeInterval(5 * 60),
                notes: store.notes
            )
            guard let brief else { throw SnapshotError.fixtureValidationFailed }
            content = AnyView(
                PrepBriefView(
                    brief: brief,
                    onSelectNote: { _ in },
                    onRecordSitting: {}
                )
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, snapshotColorScheme)
                    .transaction { $0.disablesAnimations = true }
            )
        case "ask-light", "ask-dark":
            canvasSize = CGSize(width: 560, height: 420)
            content = AnyView(
                LibraryAskView(notes: store.notes, onSelectNote: { _ in }, onClose: {})
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, snapshotColorScheme)
                    .transaction { $0.disablesAnimations = true }
            )
        case "palette-light", "palette-dark":
            canvasSize = CGSize(width: 1_220, height: 760)
            meeting.setPreviewState(phase: .idle, elapsed: 0, liveTranscript: .empty, audioLevel: 0)
            content = AnyView(
                ZStack {
                    LibraryView(initialNoteID: fixtures[0].id)
                        .environmentObject(store)
                        .environmentObject(meeting)
                        .environmentObject(markdownDraft)
                        .environmentObject(personalNotesDraft)
                        .environmentObject(prep)
                        .environmentObject(recovery)
                    CommandPaletteView(
                        isPresented: .constant(true),
                        openActionEntries: [],
                        createNote: { _ in },
                        createWeeklyDigest: {},
                        showAskSheet: {},
                        presentQuickNote: {}
                    )
                    .environmentObject(store)
                    .environmentObject(meeting)
                }
                .frame(width: canvasSize.width, height: canvasSize.height)
                .environment(\.colorScheme, snapshotColorScheme)
                .transaction { $0.disablesAnimations = true }
            )
        case "floating-notes-light", "floating-notes-dark":
            canvasSize = CGSize(width: 440, height: 500)
            meeting.setPreviewState(
                phase: .recording(title: "Nook design weekly", startedAt: Date().addingTimeInterval(-13 * 60 - 42)),
                elapsed: 13 * 60 + 42,
                liveTranscript: transcriptState,
                audioLevel: 0.64,
                liveNotes: "Ask Ana to test the new meeting prompt.\nRevisit the transition timing before Friday."
            )
            content = AnyView(
                FloatingNotesView()
                    .environmentObject(meeting)
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .environment(\.colorScheme, snapshotColorScheme)
                    .transaction { $0.disablesAnimations = true }
            )
        case "library-recording-light", "library-recording-dark":
            canvasSize = CGSize(width: 1_220, height: 760)
            meeting.setPreviewState(
                phase: .recording(title: "Nook design weekly", startedAt: Date().addingTimeInterval(-13 * 60 - 42)),
                elapsed: 13 * 60 + 42,
                liveTranscript: transcriptState,
                audioLevel: 0.64
            )
            content = AnyView(
                LibraryView(initialNoteID: fixtures[0].id)
                    .environmentObject(store)
                    .environmentObject(meeting)
                    .environmentObject(markdownDraft)
                    .environmentObject(personalNotesDraft)
                    .environmentObject(prep)
                    .environmentObject(recovery)
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .environment(\.colorScheme, snapshotColorScheme)
                    .transaction { $0.disablesAnimations = true }
            )
        case "live":
            canvasSize = CGSize(width: 1_220, height: 760)
            content = AnyView(
                LiveMeetingView(rendersForSnapshot: true)
                    .environmentObject(meeting)
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .environment(\.colorScheme, .dark)
                    .transaction { $0.disablesAnimations = true }
            )
        case "notch", "external-panel",
             "summary-light", "summary-dark",
             "notes-light", "notes-dark",
             "detected-light", "detected-dark",
             "detected-compact-light", "detected-compact-dark",
             "processing-light", "processing-dark",
             "completed-light", "completed-dark",
             "failure-light", "failure-dark":
            canvasSize = CGSize(width: 980, height: 380)
            let geometry = NotchPanelGeometry()
            geometry.topInset = mode == "notch" ? 32 : 28
            // The prompt shrinks after it has been on screen a while rather
            // than vanishing, so that second shape needs to be renderable too.
            geometry.detectionPromptIsCompact = mode.hasPrefix("detected-compact")
            let panelColorScheme: ColorScheme = mode.hasSuffix("-light")
                ? .light
                : .dark
            content = AnyView(
                ZStack(alignment: .top) {
                    NotchPreviewBackground()
                    NotchPanelView(rendersForSnapshot: true)
                        .environmentObject(meeting)
                        .environmentObject(geometry)
                    if mode == "notch" {
                        SimulatedCameraHousing()
                    }
                }
                .frame(width: canvasSize.width, height: canvasSize.height)
                .environment(\.colorScheme, panelColorScheme)
                .transaction { $0.disablesAnimations = true }
            )
        default:
            canvasSize = mode == "library-compact"
                ? CGSize(width: 900, height: 580)
                : CGSize(width: 1_220, height: 760)
            meeting.setPreviewState(
                phase: .idle,
                elapsed: 0,
                liveTranscript: .empty,
                audioLevel: 0
            )
            content = AnyView(
                LibraryView(initialNoteID: fixtures[0].id)
                    .environmentObject(store)
                    .environmentObject(meeting)
                    .environmentObject(markdownDraft)
                    .environmentObject(personalNotesDraft)
                    .environmentObject(prep)
                    .environmentObject(recovery)
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .environment(\.colorScheme, snapshotColorScheme)
                    .transaction { $0.disablesAnimations = true }
            )
        }

        let notchModes: Set<String> = ["notch","external-panel","summary-light","summary-dark","notes-light","notes-dark","detected-light","detected-dark","detected-compact-light","detected-compact-dark","processing-light","processing-dark","completed-light","completed-dark","failure-light","failure-dark","live"]
        if notchModes.contains(mode) {
            meeting.showLiveCaptions = mode != "external-panel"
            switch mode {
            case "detected-light", "detected-dark",
                 "detected-compact-light", "detected-compact-dark":
                meeting.setPreviewState(
                    phase: .detected(
                        DetectedMeeting(
                            appName: "Teams",
                            windowTitle: "Design review"
                        )
                    ),
                    elapsed: 0,
                    liveTranscript: .empty,
                    audioLevel: 0
                )
            case "completed-light", "completed-dark":
                meeting.setPreviewState(
                    phase: .completed("Weekly product review"),
                    elapsed: 77,
                    liveTranscript: .empty,
                    audioLevel: 0
                )
            case "processing-light", "processing-dark":
                meeting.setPreviewState(
                    phase: .processing(.summarizing),
                    elapsed: 13 * 60 + 42,
                    liveTranscript: transcriptState,
                    audioLevel: 0
                )
            case "failure-light", "failure-dark":
                meeting.setPreviewState(
                    phase: .failed(
                        "Screen & System Audio Recording permission is required."
                    ),
                    elapsed: 0,
                    liveTranscript: .empty,
                    audioLevel: 0
                )
            case "summary-light", "summary-dark":
                meeting.setPreviewState(
                    phase: .recording(
                        title: "Nook design weekly",
                        startedAt: Date().addingTimeInterval(-13 * 60 - 42)
                    ),
                    elapsed: 13 * 60 + 42,
                    liveTranscript: transcriptState,
                    audioLevel: 0.64,
                    panelMode: .summary,
                    liveInsights: MeetingInsights(
                        title: "Nook design weekly",
                        summary: "The team is aligning the live meeting experience around calm, glanceable information that stays close to the camera without taking over the screen.",
                        keyPoints: [
                            "Keep the spoken word visually primary.",
                            "Use restrained motion when the panel changes modes.",
                            "Let the library remain a quiet place for review."
                        ],
                        decisions: [
                            "Use one workspace for transcript, summary, and notes."
                        ],
                        actionItems: [
                            "Refine the panel transition before the next review."
                        ]
                    )
                )
            case "notes-light", "notes-dark":
                meeting.setPreviewState(
                    phase: .recording(
                        title: "Nook design weekly",
                        startedAt: Date().addingTimeInterval(-13 * 60 - 42)
                    ),
                    elapsed: 13 * 60 + 42,
                    liveTranscript: transcriptState,
                    audioLevel: 0.64,
                    panelMode: .notes,
                    liveNotes: """
                    Ask Ana to test the new meeting prompt.
                    Revisit the transition timing before Friday.
                    """
                )
            default:
                meeting.setPreviewState(
                    phase: .recording(
                        title: "Nook design weekly",
                        startedAt: Date().addingTimeInterval(-13 * 60 - 42)
                    ),
                    elapsed: 13 * 60 + 42,
                    liveTranscript: transcriptState,
                    audioLevel: 0.64,
                    panelMode: .transcript
                )
            }
        }

        // Every isolated surface receives the same app-level dependency
        // graph. Injecting it here keeps newly added modes from compiling and
        // then trapping only when an environment-backed child is rendered.
        let hostingView = NSHostingView(
            rootView: content.environmentObject(shortcuts)
        )
        hostingView.frame = NSRect(origin: .zero, size: canvasSize)
        let isLightAppearance = mode == "library-light"
            || mode.hasSuffix("-light")
        let appearance: NSAppearance.Name = isLightAppearance ? .aqua : .darkAqua
        hostingView.appearance = NSAppearance(named: appearance)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hostingView
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        guard let representation = hostingView.bitmapImageRepForCachingDisplay(
            in: hostingView.bounds
        ) else {
            throw SnapshotError.renderFailed
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        guard let data = representation.representation(
            using: .png,
            properties: [:]
        ) else {
            throw SnapshotError.encodingFailed
        }

        let outputURL = URL(fileURLWithPath: arguments[1])
        try fileManager.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: outputURL, options: .atomic)
        print(outputURL.path)
    }

    @MainActor
    private static var fixtureNotes: [MeetingNote] {
        let now = Date()
        let latestStart = now.addingTimeInterval(-48 * 60)
        let planningStart = now.addingTimeInterval(-26 * 60 * 60)
        let researchStart = now.addingTimeInterval(-3 * 24 * 60 * 60)

        return [
            MeetingNote(
                id: UUID(uuidString: "7AA62B57-3D97-471A-A312-FC2C21E75858")!,
                title: "A gentler first-run experience",
                startedAt: latestStart,
                endedAt: latestStart.addingTimeInterval(2_760),
                sourceApp: "Teams",
                summary: "The team aligned on a calmer onboarding that demonstrates value before asking for configuration. The first session should feel guided, private, and unmistakably native to the Mac.",
                keyPoints: [
                    "Begin with a short, useful sample instead of a permissions wall.",
                    "Explain local processing at the moment it matters, not as legal copy.",
                    "Keep the notch prompt compact until the user opts into recording."
                ],
                decisions: [
                    "Prototype the three-step onboarding for Friday’s review.",
                    "Use system permission sheets without recreating them in-app."
                ],
                actionItems: [
                    "Maya — refine the first-run copy by Thursday.",
                    "Leo — validate the permission sequence on a clean Mac.",
                    "Ana — prepare five usability sessions for next week."
                ],
                transcript: [
                    TranscriptSegment(
                        startTime: 4,
                        duration: 8,
                        text: "I want the first minute to feel like the product is already helping.",
                        source: .system
                    ),
                    TranscriptSegment(
                        startTime: 14,
                        duration: 7,
                        text: "Yes, and privacy should be visible without becoming the whole story.",
                        source: .microphone
                    )
                ]
            ),
            MeetingNote(
                id: UUID(uuidString: "32782918-5BA5-432C-B26C-120EBF1BA98B")!,
                title: "Summer launch planning",
                startedAt: planningStart,
                endedAt: planningStart.addingTimeInterval(3_180),
                sourceApp: "Zoom",
                summary: "Launch scope is stable and the remaining risk is documentation readiness.",
                keyPoints: ["Beta feedback is trending positive."],
                decisions: ["Keep the current launch date."],
                actionItems: ["Priya — publish the launch checklist."],
                transcript: []
            ),
            MeetingNote(
                id: UUID(uuidString: "F07DD55B-C878-4DCB-A8EC-8676A96DA912")!,
                title: "Research synthesis",
                startedAt: researchStart,
                endedAt: researchStart.addingTimeInterval(2_340),
                sourceApp: "Google Meet",
                summary: "People value confidence and retrieval more than exhaustive meeting detail.",
                keyPoints: ["Search should work across summaries and spoken words."],
                decisions: [],
                actionItems: ["Share the synthesis with the product group."],
                transcript: []
            )
        ]
    }
}

private enum SnapshotError: LocalizedError {
    case renderFailed
    case encodingFailed
    case fixtureValidationFailed

    var errorDescription: String? {
        switch self {
        case .renderFailed: "SwiftUI did not produce a snapshot image."
        case .encodingFailed: "The rendered image could not be encoded as PNG."
        case .fixtureValidationFailed: "The Markdown fixture did not round-trip correctly."
        }
    }
}

private struct NotchPreviewBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [
                        Color(red: 0.10, green: 0.13, blue: 0.19),
                        Color(red: 0.20, green: 0.13, blue: 0.16),
                        Color(red: 0.06, green: 0.08, blue: 0.12),
                    ]
                    : [
                        Color(red: 0.94, green: 0.95, blue: 0.97),
                        Color(red: 0.88, green: 0.91, blue: 0.94),
                        Color(red: 0.80, green: 0.85, blue: 0.90),
                    ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            HStack(spacing: 18) {
                Image(systemName: "apple.logo")
                Text("Nook")
                    .font(.system(size: 12, weight: .semibold))
                Text("File")
                Text("Edit")
                Spacer()
                Image(systemName: "wifi")
                Image(systemName: "battery.100percent")
                Text("Wed 1:14 PM")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(
                colorScheme == .dark
                    ? Color.white.opacity(0.86)
                    : Color.black.opacity(0.76)
            )
            .padding(.horizontal, 16)
            .frame(height: 28)
            .background(
                colorScheme == .dark
                    ? Color.black.opacity(0.42)
                    : Color.white.opacity(0.70)
            )
        }
    }
}

private struct SimulatedCameraHousing: View {
    var body: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 11,
            bottomTrailingRadius: 11,
            topTrailingRadius: 0,
            style: .continuous
        )
        .fill(.black)
        .frame(width: 184, height: 32)
        .accessibilityHidden(true)
    }
}

struct SnapshotCalendarProvider: CalendarEventProviding {
    func requestAccess() async -> Bool { true }
    func events(between start: Date, end: Date) -> [CalendarMeetingEvent] {
        [CalendarMeetingEvent(title: "Research synthesis", attendeeCount: 4, startDate: Date().addingTimeInterval(5 * 60))]
    }
}
