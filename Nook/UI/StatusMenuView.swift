import AppKit
import Combine
import SwiftUI

/// Nook's native menu-bar menu.
///
/// Every command here is Title Case, which is the macOS convention for a menu
/// and what the app's own Meeting menu, Settings… and Check for Updates…
/// already used. Half of this menu was sentence case, so the same verb was
/// written two ways depending on which menu the user opened it from.
struct StatusMenuView: View {
    @EnvironmentObject private var updater: NookUpdateController
    @Environment(\.openSettings) private var openSettings
    @StateObject private var state = StatusMenuState()

    var body: some View {
        Group {
            statusHeader

            Divider()

            meetingCommands

            Divider()

            if let version = updater.availableVersion {
                Button {
                    updater.checkForUpdates()
                } label: {
                    Label(
                        "Nook \(version) is ready…",
                        systemImage: "arrow.down.circle.fill"
                    )
                }

                Divider()
            }

            Button {
                AppModel.shared.openLibrary()
            } label: {
                Label("Open Library", systemImage: "books.vertical")
            }
            .keyboardShortcut("o")

            Button {
                AppModel.shared.store.openStorageDirectory()
            } label: {
                Label("Open Notes Folder", systemImage: "folder")
            }

            if !state.recentNotes.isEmpty {
                Menu("Recent Meetings") {
                    ForEach(state.recentNotes) { note in
                        Button(note.title) {
                            AppModel.shared.store.reveal(note)
                        }
                    }
                }
            }

            Divider()

            Button("Settings…") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",")

            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)

            Button("Quit Nook") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    @ViewBuilder
    private var meetingCommands: some View {
        switch state.phase {
        case .recording:
            recordingCommands
        case .processing(let step):
            if step != .discarding {
                Button {
                    AppModel.shared.meeting.requestProcessingCancellation()
                } label: {
                    Label(
                        "Cancel and Discard Recording",
                        systemImage: "trash"
                    )
                }
                .disabled(!state.canCancelProcessing)
            }
        case .detected(let detection):
            Button {
                AppModel.shared.meeting.startDetectedMeeting()
            } label: {
                Label(
                    "Record “\(detection.suggestedTitle)”",
                    systemImage: "waveform"
                )
            }

            Button {
                AppModel.shared.meeting.dismissPrompt()
            } label: {
                Label("Not Now", systemImage: "xmark")
            }
        case .failed:
            Button {
                AppModel.shared.meeting.resetStatus()
            } label: {
                Label("Dismiss", systemImage: "xmark.circle")
            }
        case .completed:
            Button {
                AppModel.shared.openLatestMeeting()
            } label: {
                Label("Open Note", systemImage: "doc.text")
            }
        case .idle:
            Button {
                AppModel.shared.meeting.startManualMeeting()
            } label: {
                Label("Start Recording", systemImage: "waveform.badge.mic")
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }

    private var recordingCommands: some View {
        Group {
            Button {
                AppModel.shared.meeting.flagMoment()
            } label: {
                Label("Flag This Moment", systemImage: "flag")
            }
            .keyboardShortcut("f", modifiers: [.command, .option])

            Button {
                AppModel.shared.meeting.togglePause()
            } label: {
                Label(
                    state.isPaused ? "Resume Recording" : "Pause Recording",
                    systemImage: state.isPaused
                        ? "play.circle"
                        : "pause.circle"
                )
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(state.pauseTransitionInFlight)

            Button {
                AppModel.shared.meeting.stopRecording()
            } label: {
                Label("Finish Meeting", systemImage: "stop.circle.fill")
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            .disabled(state.pauseTransitionInFlight)

            Divider()

            if state.topPanelHidden {
                Button {
                    AppModel.shared.meeting.restoreTopPanel()
                } label: {
                    Label("Show Top Panel", systemImage: "rectangle.expand.vertical")
                }
            } else {
                Button {
                    if state.showsWorkspace {
                        AppModel.shared.meeting.collapseTopPanel()
                    } else {
                        AppModel.shared.meeting.expandTopPanel()
                    }
                } label: {
                    Label(
                        state.showsWorkspace
                            ? "Collapse Top Panel"
                            : "Expand Top Panel",
                        systemImage: state.showsWorkspace
                            ? "rectangle.compress.vertical"
                            : "rectangle.expand.vertical"
                    )
                }

                Button {
                    AppModel.shared.meeting.hideTopPanel()
                } label: {
                    Label("Hide Top Panel", systemImage: "rectangle.slash")
                }

                if state.showsWorkspace {
                    Menu("Workspace View") {
                        ForEach(MeetingPanelMode.allCases) { mode in
                            Button {
                                AppModel.shared.meeting.selectPanelMode(mode)
                            } label: {
                                Label(
                                    mode.label,
                                    systemImage: state.panelMode == mode
                                        ? "checkmark"
                                        : mode.symbol
                                )
                            }
                        }
                    }
                }
            }

            Button {
                AppModel.shared.openLiveNotes()
            } label: {
                Label(
                    "Open Floating Notes",
                    systemImage: "macwindow.on.rectangle"
                )
            }
        }
    }

    @ViewBuilder
    private var statusHeader: some View {
        switch state.phase {
        case .recording:
            Label(
                state.isPaused ? "Recording paused" : "Recording",
                systemImage: state.isPaused
                    ? "pause.circle.fill"
                    : "record.circle.fill"
            )
            .foregroundStyle(
                state.isPaused ? NookPalette.warning : NookPalette.danger
            )
            .disabled(true)
        case .processing(let step):
            Label(
                step.rawValue,
                systemImage: step == .discarding
                    ? "trash"
                    : "ellipsis.circle"
            )
            .disabled(true)
        case .detected(let detection):
            Label(
                "Meeting detected in \(detection.appName)",
                systemImage: "sparkle.magnifyingglass"
            )
            .disabled(true)
        case .failed:
            Label(
                "Nook needs attention",
                systemImage: "exclamationmark.circle"
            )
            .disabled(true)
        case .completed:
            Label("Meeting saved", systemImage: "checkmark.circle.fill")
                .disabled(true)
        case .idle:
            Label("Ready · stays on this Mac", systemImage: "lock.fill")
                .disabled(true)
        }
    }
}

enum StatusMenuPhase: Equatable {
    case idle
    case detected(DetectedMeeting)
    case recording
    case processing(MeetingPhase.ProcessingStep)
    case completed
    case failed

    init(_ phase: MeetingPhase) {
        switch phase {
        case .idle:
            self = .idle
        case .detected(let detection):
            self = .detected(detection)
        case .recording:
            self = .recording
        case .processing(let step):
            self = .processing(step)
        case .completed:
            self = .completed
        case .failed:
            self = .failed
        }
    }
}

/// A deliberately low-frequency model for the native status menu.
///
/// The recording clock lives in the menu-bar label. Subscribing the menu
/// itself to that clock causes AppKit to rebuild and move menu items while the
/// pointer is over them, so this model observes only state that changes the
/// available commands.
@MainActor
final class StatusMenuState: ObservableObject {
    @Published private(set) var phase: StatusMenuPhase
    @Published private(set) var isPaused: Bool
    @Published private(set) var pauseTransitionInFlight: Bool
    @Published private(set) var showsWorkspace: Bool
    @Published private(set) var topPanelHidden: Bool
    @Published private(set) var panelMode: MeetingPanelMode
    @Published private(set) var canCancelProcessing: Bool
    @Published private(set) var recentNotes: [MeetingNote]

    private var cancellables: Set<AnyCancellable> = []

    init(
        meeting: MeetingCoordinator = AppModel.shared.meeting,
        store: MarkdownStore = AppModel.shared.store
    ) {
        phase = StatusMenuPhase(meeting.phase)
        isPaused = meeting.isPaused
        pauseTransitionInFlight = meeting.pauseTransitionInFlight
        showsWorkspace = meeting.showLiveCaptions
        topPanelHidden = meeting.topPanelHidden
        panelMode = meeting.panelMode
        canCancelProcessing = meeting.canCancelProcessing
        recentNotes = Array(store.notes.prefix(5))

        meeting.$phase
            .map(StatusMenuPhase.init)
            .removeDuplicates()
            .sink { [weak self, weak meeting] phase in
                self?.phase = phase
                Task { @MainActor [weak self, weak meeting] in
                    // @Published emits in willSet. Yield once before reading
                    // the coordinator's derived processing capability.
                    await Task.yield()
                    self?.canCancelProcessing =
                        meeting?.canCancelProcessing ?? false
                }
            }
            .store(in: &cancellables)

        meeting.$isPaused
            .removeDuplicates()
            .sink { [weak self] in self?.isPaused = $0 }
            .store(in: &cancellables)

        meeting.$pauseTransitionInFlight
            .removeDuplicates()
            .sink { [weak self] in self?.pauseTransitionInFlight = $0 }
            .store(in: &cancellables)

        meeting.$showLiveCaptions
            .removeDuplicates()
            .sink { [weak self] in self?.showsWorkspace = $0 }
            .store(in: &cancellables)

        meeting.$topPanelHidden
            .removeDuplicates()
            .sink { [weak self] in self?.topPanelHidden = $0 }
            .store(in: &cancellables)

        meeting.$panelMode
            .removeDuplicates()
            .sink { [weak self] in self?.panelMode = $0 }
            .store(in: &cancellables)

        store.$notes
            .map { Array($0.prefix(5)) }
            .removeDuplicates()
            .sink { [weak self] in self?.recentNotes = $0 }
            .store(in: &cancellables)
    }
}
