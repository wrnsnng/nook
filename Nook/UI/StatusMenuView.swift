import AppKit
import SwiftUI

struct StatusMenuView: View {
    @EnvironmentObject private var meeting: MeetingCoordinator
    @EnvironmentObject private var store: MarkdownStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            statusHeader

            Divider()

            if meeting.phase.isRecording {
                Button {
                    meeting.togglePause()
                } label: {
                    Label(
                        meeting.isPaused ? "Resume recording" : "Pause recording",
                        systemImage: meeting.isPaused
                            ? "play.circle"
                            : "pause.circle"
                    )
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(meeting.pauseTransitionInFlight)

                Button {
                    meeting.stopRecording()
                } label: {
                    Label("Finish meeting", systemImage: "stop.circle.fill")
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(meeting.pauseTransitionInFlight)

                Toggle(
                    "Expanded meeting workspace",
                    isOn: $meeting.showLiveCaptions
                )

                if meeting.showLiveCaptions {
                    Menu("Top panel view") {
                        ForEach(MeetingPanelMode.allCases) { mode in
                            Button {
                                meeting.selectPanelMode(mode)
                            } label: {
                                Label(
                                    mode.label,
                                    systemImage: meeting.panelMode == mode
                                        ? "checkmark"
                                        : mode.symbol
                                )
                            }
                        }
                    }
                }

                Button {
                    AppModel.shared.openLiveNotes()
                } label: {
                    Label("Open floating notes", systemImage: "macwindow.on.rectangle")
                }
            } else {
                Button {
                    meeting.startManualMeeting()
                } label: {
                    Label("Start recording", systemImage: "waveform.badge.mic")
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }

            Divider()

            Button {
                openLibrary()
            } label: {
                Label("Open meeting library", systemImage: "books.vertical")
            }
            .keyboardShortcut("o")

            Button {
                store.openStorageDirectory()
            } label: {
                Label("Open notes folder", systemImage: "folder")
            }

            if !store.notes.isEmpty {
                Menu("Recent meetings") {
                    ForEach(store.notes.prefix(5)) { note in
                        Button {
                            store.reveal(note)
                        } label: {
                            Text(note.title)
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

            Button("Quit Nook") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    @ViewBuilder
    private var statusHeader: some View {
        switch meeting.phase {
        case .recording(let title, _):
            Label(
                "\(meeting.isPaused ? "Paused" : title) · \(elapsedLabel)",
                systemImage: meeting.isPaused
                    ? "pause.circle.fill"
                    : "record.circle.fill"
            )
            .foregroundStyle(
                meeting.isPaused ? NookPalette.warning : NookPalette.danger
            )
            .disabled(true)
        case .processing(let step):
            Label(step.rawValue, systemImage: "sparkles")
                .disabled(true)
        case .detected(let detection):
            Label(
                "Meeting detected in \(detection.appName)",
                systemImage: "sparkle.magnifyingglass"
            )
            .disabled(true)
        case .failed:
            Label("Nook needs attention", systemImage: "exclamationmark.circle")
                .disabled(true)
        default:
            Label("Ready · stays on this Mac", systemImage: "lock.fill")
                .disabled(true)
        }
    }

    private var elapsedLabel: String {
        let total = Int(meeting.elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func openLibrary() {
        AppModel.shared.openLibrary()
    }
}
