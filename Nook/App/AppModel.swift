import AppKit
import Combine
import Foundation

extension Notification.Name {
    static let nookOpenMeetingNote = Notification.Name(
        "com.localfirst.nook.open-meeting-note"
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

        meeting.onPresentationRequested = { [weak panel] in
            panel?.show()
        }
        meeting.onPanelInteractionRequested = { [weak panel] in
            panel?.makeInteractive()
        }
        meeting.onPanelDismissRequested = { [weak panel] in
            panel?.hide()
        }
        meeting.onMeetingNotificationRequested = { [weak notifications] detection in
            notifications?.present(detection)
        }
        meeting.onRecordingStopped = { [weak self] in
            self?.closeLiveNotes()
        }
        meeting.$phase
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] phase in
                guard !phase.isRecording else { return }
                self?.closeLiveNotes()
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
        UserDefaults.standard.set(true, forKey: "hasSeenWelcome")
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
