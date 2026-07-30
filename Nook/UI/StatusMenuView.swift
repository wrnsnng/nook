import AppKit
import SwiftUI

struct StatusMenuView: View {
    @EnvironmentObject private var updater: NookUpdateController
    @Environment(\.openSettings) private var openSettings
    @State private var snapshot = StatusMenuSnapshot()

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
                Label("Open meeting library", systemImage: "books.vertical")
            }
            .keyboardShortcut("o")

            Button {
                AppModel.shared.store.openStorageDirectory()
            } label: {
                Label("Open notes folder", systemImage: "folder")
            }

            if !snapshot.recentNotes.isEmpty {
                Menu("Recent meetings") {
                    ForEach(snapshot.recentNotes) { note in
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
        // MenuBarExtra hosts native NSMenu items. Taking one immutable snapshot
        // when the menu opens prevents the one-second recording clock from
        // rebuilding and moving those items underneath the pointer.
        .onAppear {
            snapshot = StatusMenuSnapshot.capture()
        }
    }

    @ViewBuilder
    private var meetingCommands: some View {
        switch snapshot.phase {
        case .recording:
            recordingCommands
        case .processing(let step):
            if step != .discarding {
                Button {
                    AppModel.shared.meeting.cancelProcessing()
                } label: {
                    Label(
                        "Cancel and discard recording",
                        systemImage: "trash"
                    )
                }
                .disabled(!snapshot.canCancelProcessing)
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
                Label("Not now", systemImage: "xmark")
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
                Label("Open saved meeting", systemImage: "doc.text")
            }
        case .idle:
            Button {
                AppModel.shared.meeting.startManualMeeting()
            } label: {
                Label("Start recording", systemImage: "waveform.badge.mic")
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }

    private var recordingCommands: some View {
        Group {
            Button {
                AppModel.shared.meeting.togglePause()
            } label: {
                Label(
                    snapshot.isPaused ? "Resume recording" : "Pause recording",
                    systemImage: snapshot.isPaused
                        ? "play.circle"
                        : "pause.circle"
                )
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(snapshot.pauseTransitionInFlight)

            Button {
                AppModel.shared.meeting.stopRecording()
            } label: {
                Label("Finish meeting", systemImage: "stop.circle.fill")
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            .disabled(snapshot.pauseTransitionInFlight)

            Divider()

            if snapshot.topPanelHidden {
                Button {
                    AppModel.shared.meeting.restoreTopPanel()
                } label: {
                    Label("Show top panel", systemImage: "rectangle.expand.vertical")
                }
            } else {
                Button {
                    if snapshot.showsWorkspace {
                        AppModel.shared.meeting.collapseTopPanel()
                    } else {
                        AppModel.shared.meeting.expandTopPanel()
                    }
                } label: {
                    Label(
                        snapshot.showsWorkspace
                            ? "Collapse top panel"
                            : "Expand top panel",
                        systemImage: snapshot.showsWorkspace
                            ? "rectangle.compress.vertical"
                            : "rectangle.expand.vertical"
                    )
                }

                Button {
                    AppModel.shared.meeting.hideTopPanel()
                } label: {
                    Label("Hide top panel", systemImage: "rectangle.slash")
                }

                if snapshot.showsWorkspace {
                    Menu("Workspace view") {
                        ForEach(MeetingPanelMode.allCases) { mode in
                            Button {
                                AppModel.shared.meeting.selectPanelMode(mode)
                            } label: {
                                Label(
                                    mode.label,
                                    systemImage: snapshot.panelMode == mode
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
                    "Open floating notes",
                    systemImage: "macwindow.on.rectangle"
                )
            }
        }
    }

    @ViewBuilder
    private var statusHeader: some View {
        switch snapshot.phase {
        case .recording:
            Label(
                "\(snapshot.isPaused ? "Recording paused" : "Recording") · \(snapshot.elapsedLabel)",
                systemImage: snapshot.isPaused
                    ? "pause.circle.fill"
                    : "record.circle.fill"
            )
            .foregroundStyle(
                snapshot.isPaused ? NookPalette.warning : NookPalette.danger
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

private struct StatusMenuSnapshot {
    var phase: MeetingPhase = .idle
    var elapsed: TimeInterval = 0
    var isPaused = false
    var pauseTransitionInFlight = false
    var showsWorkspace = true
    var topPanelHidden = false
    var panelMode: MeetingPanelMode = .transcript
    var canCancelProcessing = false
    var recentNotes: [MeetingNote] = []

    var elapsedLabel: String {
        let total = Int(elapsed)
        if total >= 3_600 {
            return String(
                format: "%02d:%02d",
                total / 3_600,
                (total / 60) % 60
            )
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    @MainActor
    static func capture() -> Self {
        let model = AppModel.shared
        return Self(
            phase: model.meeting.phase,
            elapsed: model.meeting.elapsed,
            isPaused: model.meeting.isPaused,
            pauseTransitionInFlight: model.meeting.pauseTransitionInFlight,
            showsWorkspace: model.meeting.showLiveCaptions,
            topPanelHidden: model.meeting.topPanelHidden,
            panelMode: model.meeting.panelMode,
            canCancelProcessing: model.meeting.canCancelProcessing,
            recentNotes: Array(model.store.notes.prefix(5))
        )
    }
}
