import AppKit
import Combine
import Foundation

extension Notification.Name {
    static let nookOpenMeetingNote = Notification.Name(
        "com.localfirst.nook.open-meeting-note"
    )
    /// The Prep brief notification action was tapped; open the library.
    static let nookRequestPrepBrief = Notification.Name(
        "com.localfirst.nook.request-prep-brief"
    )
    /// The library window should select its prep surface.
    static let nookOpenPrepBrief = Notification.Name(
        "com.localfirst.nook.open-prep-brief"
    )
}

enum NookWindowRole: String, Hashable {
    case library
    case welcome
    case liveNotes
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let appearance: NookAppearanceController
    let store: MarkdownStore
    let markdownDraft: MarkdownDraftController
    let detector: MeetingDetector
    let meeting: MeetingCoordinator
    let panel: NotchPanelCoordinator
    let notifications: MeetingNotificationService
    let dictation: DictationCoordinator
    let quickNote: QuickNoteController
    let calendar: CalendarContextService
    let prep: PrepBriefController
    let recovery: RecordingRecovery
    private let dictationIndicator = DictationIndicatorController()
    private var openLibraryAction: (@MainActor () -> Void)?
    private var openWelcomeAction: (@MainActor () -> Void)?
    private var openLiveNotesAction: (@MainActor () -> Void)?
    private var closeLiveNotesAction: (@MainActor () -> Void)?
    private var visibleWindowRoles: Set<NookWindowRole> = []
    private weak var liveNotesWindow: NSWindow?
    private var presentedLaunchExperience = false
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        let appearance = NookAppearanceController()
        let store = MarkdownStore()
        let markdownDraft = MarkdownDraftController()
        let detector = MeetingDetector()
        let meeting = MeetingCoordinator(store: store, detector: detector)
        let notifications = MeetingNotificationService(meeting: meeting)
        self.appearance = appearance
        self.store = store
        self.markdownDraft = markdownDraft
        self.detector = detector
        self.meeting = meeting
        self.panel = NotchPanelCoordinator(meeting: meeting)
        self.notifications = notifications
        let dictation = DictationCoordinator(
            localeIdentifier: meeting.localeIdentifier
        )
        let quickNote = QuickNoteController(store: store)
        self.recovery = RecordingRecovery(store: store)
        dictation.quickNote = quickNote
        self.dictation = dictation
        self.quickNote = quickNote
        let calendar = CalendarContextService()
        self.calendar = calendar
        meeting.calendarContext = calendar
        let prep = PrepBriefController(store: store, calendar: calendar)
        self.prep = prep
        calendar.onUpcomingEvent = { [weak notifications, weak store] event in
            // The notification's Record action routes back through
            // MeetingNotificationService, so nothing starts without a tap.
            // When this series has history, the notification says so and
            // gains the Prep brief action.
            let seriesKey = SeriesMatcher.seriesKey(for: event.title)
            let priorSittings = store?.notes.filter { note in
                note.kind != .digest
                    && SeriesMatcher.seriesKey(for: note.title) == seriesKey
            }.count ?? 0
            notifications?.present(
                upcoming: event,
                priorSittings: priorSittings
            )
        }

        NotificationCenter.default
            .publisher(for: .nookRequestPrepBrief)
            .sink { [weak self] _ in
                self?.openPrepBrief()
            }
            .store(in: &cancellables)

        meeting.onPresentationRequested = { [weak panel] in
            panel?.show()
        }
        meeting.onPanelInteractionRequested = { [weak panel] in
            panel?.makeInteractive()
        }
        meeting.onPanelDismissRequested = { [weak panel] in
            // "Fully hidden" keeps a tiny recording timer attached to the
            // camera housing so the meeting can always be recovered.
            panel?.show()
        }
        meeting.onMeetingNotificationRequested = { [weak notifications] detection in
            notifications?.present(detection)
        }
        meeting.onRecordingStopped = { [weak self] in
            self?.closeLiveNotes()
        }

        // A recording kept after a processing failure is discoverable only in
        // Settings today. Scanning once the first library load has settled
        // surfaces it at launch instead, which matters because a user who
        // missed the failure message has no other reason to open that pane.
        // Waiting for the load also gives the scan the saved-note
        // identifiers it needs to leave finished meetings' audio alone.
        store.$isLoading
            .dropFirst()
            .first { !$0 }
            .sink { [weak self] _ in
                self?.recovery.scan()
                AudioRetention.sweep(store: store)
            }
            .store(in: &cancellables)

        // A meeting that is recording or still being written up has audio in
        // the recordings folder and no note yet, which is exactly what a
        // stranded recording looks like. MeetingCoordinator keeps its draft
        // private, so the phase is what can be forwarded: the pane lists
        // nothing while a meeting is in flight rather than offering to delete
        // the one in progress.
        meeting.$phase
            .removeDuplicates()
            // The starting phase is idle, which is what this already assumes.
            .dropFirst()
            .sink { [weak self] phase in
                switch phase {
                case .recording, .processing:
                    self?.recovery.activeRecording = .inFlight(nil)
                default:
                    self?.recovery.activeRecording = .none
                }
            }
            .store(in: &cancellables)

        calendar.restoreSessionIfNeeded()
        meeting.$phase
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] phase in
                guard !phase.isRecording else { return }
                self?.closeLiveNotes()
            }
            .store(in: &cancellables)

        // One "spoken language" choice covers both meetings and dictation.
        meeting.$localeIdentifier
            .removeDuplicates()
            .sink { [weak dictation] identifier in
                dictation?.updateLocale(identifier)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(
            dictation.$phase.removeDuplicates(),
            dictation.$audioLevel,
            dictation.$volatileText.removeDuplicates()
        )
        .sink { [weak self] phase, level, volatileText in
            guard let self else { return }
            // The indicator follows the pointer because dictation usually
            // happens in someone else's text field. When the quick note pad is
            // the field, it shows the same live guess inline, and two copies
            // of the same half-heard sentence on screen at once read as a
            // stutter rather than as feedback.
            let padIsTheField = self.quickNote.isFrontmost
            self.dictationIndicator.update(
                phase: padIsTheField ? .idle : phase,
                level: level,
                volatileText: volatileText
            )
        }
        .store(in: &cancellables)

        detector.start()
    }

    func installWindowActions(
        openLibrary: @escaping @MainActor () -> Void,
        openWelcome: @escaping @MainActor () -> Void,
        openLiveNotes: @escaping @MainActor () -> Void,
        closeLiveNotes: @escaping @MainActor () -> Void
    ) {
        openLibraryAction = openLibrary
        openWelcomeAction = openWelcome
        openLiveNotesAction = openLiveNotes
        closeLiveNotesAction = closeLiveNotes
        presentLaunchExperience()
    }

    func openLibrary(noteID: MeetingNote.ID? = nil) {
        promoteToWindowedApp()
        openLibraryAction?()
        NSApp.activate(ignoringOtherApps: true)
        if let noteID {
            Task { @MainActor in
                // A newly created SwiftUI window installs its subscriptions on
                // the next run-loop passes. Delay this targeted selection just
                // enough for both first-open and already-open library windows.
                try? await Task.sleep(for: .milliseconds(140))
                NotificationCenter.default.post(
                    name: .nookOpenMeetingNote,
                    object: noteID
                )
            }
        }
    }

    func openLatestMeeting() {
        store.reload()
        openLibrary(noteID: store.notes.first?.id)
    }

    /// Opens the library on its prep surface, when a brief is current.
    ///
    /// Mirrors the note-selection delay in `openLibrary(noteID:)`: a freshly
    /// opening window installs its selection handling a run loop or two late,
    /// and the targeted notification must survive that.
    func openPrepBrief() {
        openLibrary()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard self?.prep.current != nil else { return }
            NotificationCenter.default.post(
                name: .nookOpenPrepBrief,
                object: nil
            )
        }
    }

    func openIntroduction() {
        promoteToWindowedApp()
        openWelcomeAction?()
        NSApp.activate(ignoringOtherApps: true)
    }

    func openLiveNotes() {
        guard meeting.phase.isRecording else { return }
        meeting.setLiveNotesDetached(true)
        promoteToWindowedApp()
        openLiveNotesAction?()
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidOpen(_ role: NookWindowRole, window: NSWindow) {
        visibleWindowRoles.insert(role)
        if role == .liveNotes {
            liveNotesWindow = window
            meeting.setLiveNotesDetached(true)
        }
        promoteToWindowedApp()
    }

    func windowDidClose(_ role: NookWindowRole) {
        visibleWindowRoles.remove(role)
        if role == .liveNotes {
            liveNotesWindow = nil
            meeting.setLiveNotesDetached(false)
        }
        guard visibleWindowRoles.isEmpty else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    private func closeLiveNotes() {
        // The view that owns the floating window receives this synchronously,
        // which avoids SwiftUI scene reconciliation keeping a stale editor
        // alive after the meeting has already moved into processing.
        NotificationCenter.default.post(
            name: .nookCloseLiveNotesWindow,
            object: nil
        )

        if meeting.liveNotesDetached {
            meeting.setLiveNotesDetached(false)
        }
        liveNotesWindow?.standardWindowButton(.closeButton)?.performClick(nil)
        liveNotesWindow?.orderOut(nil)
        let identifier = NSUserInterfaceItemIdentifier(
            "nook.\(NookWindowRole.liveNotes.rawValue)"
        )
        if let window = NSApp.windows.first(where: {
            $0.identifier == identifier
        }) {
            window.standardWindowButton(.closeButton)?.performClick(nil)
            window.orderOut(nil)
        }

        // A phase publication can arrive while SwiftUI is still reconciling
        // the meeting workspace. Defer window work to the next main-actor turn
        // so the floating scene cannot reject or immediately undo the close.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()

            if let window = NSApp.windows.first(where: {
                $0.identifier == identifier
            }) {
                // Hide first so the user never watches a stale note window
                // through the processing transition, then close the scene.
                window.orderOut(nil)
                window.close()
            }
            closeLiveNotesAction?()
        }
    }

    func completeWelcome() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "automaticDetection") == nil {
            // Dismissing setup without touching the toggle is still an
            // explicit choice to keep detection off. Persist it so the legacy
            // `hasSeenWelcome` fallback cannot enable detection next launch.
            defaults.set(detector.isEnabled, forKey: "automaticDetection")
        }
        defaults.set(true, forKey: "hasSeenWelcome")
    }

    private func presentLaunchExperience() {
        guard !presentedLaunchExperience else { return }
        presentedLaunchExperience = true

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(where: {
            $0.hasPrefix("--audit-")
        }) {
            return
        }
        #endif

        if meeting.resumePendingStartAfterPermission() {
            return
        }

        if !UserDefaults.standard.bool(forKey: "hasSeenWelcome") {
            promoteToWindowedApp()
            openWelcomeAction?()
            NSApp.activate(ignoringOtherApps: true)
        } else {
            panel.showLaunchConfirmation()
        }
    }

    private func promoteToWindowedApp() {
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
    }
}
