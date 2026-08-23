import SwiftUI

@main
struct NookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel.shared
    @StateObject private var updater = NookUpdateController()

    var body: some Scene {
        MenuBarExtra {
            StatusMenuView()
                .environmentObject(updater)
        } label: {
            NookMenuBarLabel()
                .environmentObject(appModel.meeting)
                .environmentObject(updater)
                .background(WindowRouterBridge())
        }

        Window("Nook", id: "library") {
            LibraryView()
                .environmentObject(appModel.meeting)
                .environmentObject(appModel.store)
                .environmentObject(appModel.markdownDraft)
                .environmentObject(appModel.prep)
                .frame(minWidth: 900, minHeight: 580)
                .background(NookWindowBridge(role: .library))
        }
        .defaultSize(width: 1_080, height: 680)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CheckForUpdatesCommand(updater: updater)

            CommandMenu("Meeting") {
                if appModel.meeting.phase.isRecording {
                    Button(
                        appModel.meeting.isPaused
                            ? "Resume Recording"
                            : "Pause Recording"
                    ) {
                        appModel.meeting.togglePause()
                    }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(appModel.meeting.pauseTransitionInFlight)

                    Button("Finish Meeting") {
                        appModel.meeting.stopRecording()
                    }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                    .disabled(appModel.meeting.pauseTransitionInFlight)
                } else {
                    Button("Start Recording") {
                        appModel.meeting.startManualMeeting()
                    }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                }
            }

            CommandGroup(replacing: .help) {
                Button("Nook Setup…") {
                    appModel.openIntroduction()
                }

                Link(
                    "Common Tools Co.",
                    destination: URL(string: "https://www.common-tools.co/")!
                )
            }
        }

        Window("Welcome to Nook", id: "welcome") {
            WelcomeView(appModel: appModel)
                .background(NookWindowBridge(role: .welcome))
        }
        .defaultSize(width: 680, height: 560)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))

        Window("My Notes", id: "live-notes") {
            FloatingNotesView()
                .environmentObject(appModel.meeting)
                .frame(minWidth: 360, minHeight: 320)
        }
        .defaultSize(width: 440, height: 500)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))

        Settings {
            SettingsView()
                .environmentObject(appModel.store)
                .environmentObject(appModel.detector)
                .environmentObject(appModel.meeting)
                .environmentObject(appModel.appearance)
                .environmentObject(appModel.dictation)
                .environmentObject(appModel.quickNote)
                .environmentObject(appModel.recovery)
                .environmentObject(appModel.calendar)
                .environmentObject(updater)
                .frame(width: 620, height: 540)
        }
    }
}

private struct NookMenuBarLabel: View {
    @EnvironmentObject private var meeting: MeetingCoordinator
    @EnvironmentObject private var updater: NookUpdateController

    var body: some View {
        HStack(spacing: 3) {
            Group {
                if meeting.phase.isRecording {
                    HStack(spacing: 5) {
                        Image(
                            systemName: meeting.isPaused
                                ? "pause.fill"
                                : "record.circle.fill"
                        )
                        .frame(width: 13)
                        Text(elapsedLabel)
                            .font(.system(.caption, design: .monospaced))
                            .monospacedDigit()
                            .frame(width: 38, alignment: .leading)
                    }
                } else {
                    Image(systemName: menuBarSymbol)
                }
            }

            // A build from source and an installed release are both called
            // "Nook" and carry the same icon, so side by side in the menu bar
            // they are indistinguishable — and acting on the wrong one is easy.
            // The marker is derived from the existing official-build identity
            // rather than a separate name, so a release cannot ever show it.
            if !isOfficialBuild {
                Text("DEV")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .opacity(0.75)
            }
        }
        .foregroundStyle(
            meeting.phase.isRecording
                ? (meeting.isPaused
                    ? NookPalette.warning
                    : NookPalette.danger)
                : .primary
        )
        .accessibilityLabel(
            accessibilityLabel
        )
    }

    private var isOfficialBuild: Bool {
        NookBuildIdentity.permitsOfficialUpdates
    }

    private var menuBarSymbol: String {
        if meeting.phase.isRecording {
            return meeting.phase.menuBarSymbol
        }
        if updater.availableVersion != nil {
            return "arrow.down.circle.fill"
        }
        return meeting.phase.menuBarSymbol
    }

    private var accessibilityLabel: String {
        let name = isOfficialBuild ? "Nook" : "Nook, development build"
        if meeting.isPaused {
            return "\(name), recording paused, \(elapsedSpokenLabel)"
        }
        if meeting.phase.isRecording {
            return "\(name), recording, \(elapsedSpokenLabel)"
        }
        if let version = updater.availableVersion {
            return "\(name), version \(version) is ready"
        }
        return name
    }

    private var elapsedLabel: String {
        let total = Int(meeting.elapsed)
        if total >= 3_600 {
            return String(
                format: "%02d:%02d",
                total / 3_600,
                (total / 60) % 60
            )
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private var elapsedSpokenLabel: String {
        let total = Int(meeting.elapsed)
        return "\(total / 60) minutes, \(total % 60) seconds"
    }
}

private struct WindowRouterBridge: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                AppModel.shared.installWindowActions(
                    openLibrary: { openWindow(id: "library") },
                    openWelcome: { openWindow(id: "welcome") },
                    openLiveNotes: { openWindow(id: "live-notes") },
                    closeLiveNotes: { dismissWindow(id: "live-notes") }
                )
            }
    }
}
