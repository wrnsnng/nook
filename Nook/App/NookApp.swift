import SwiftUI

@main
struct NookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            StatusMenuView()
                .environmentObject(appModel.meeting)
                .environmentObject(appModel.store)
                .environmentObject(appModel.detector)
        } label: {
            NookMenuBarLabel()
                .environmentObject(appModel.meeting)
                .background(WindowRouterBridge())
        }

        Window("Nook", id: "library") {
            LibraryView()
                .environmentObject(appModel.meeting)
                .environmentObject(appModel.store)
                .environmentObject(appModel.markdownDraft)
                .frame(minWidth: 900, minHeight: 580)
                .background(NookWindowBridge(role: .library))
        }
        .defaultSize(width: 1_080, height: 680)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
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
                Button("Nook Introduction…") {
                    appModel.openIntroduction()
                }

                Link(
                    "Common Tools Co.",
                    destination: URL(string: "https://www.common-tools.co/")!
                )
            }
        }

        Window("Welcome to Nook", id: "welcome") {
            WelcomeView()
                .environmentObject(appModel)
                .background(NookWindowBridge(role: .welcome))
        }
        .defaultSize(width: 560, height: 430)
        .windowResizability(.contentSize)
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
                .frame(width: 620, height: 540)
        }
    }
}

private struct NookMenuBarLabel: View {
    @EnvironmentObject private var meeting: MeetingCoordinator

    var body: some View {
        Label(
            "Nook",
            systemImage: meeting.isPaused
                ? "pause.circle.fill"
                : meeting.phase.menuBarSymbol
        )
        .accessibilityLabel(
            meeting.isPaused ? "Nook, recording paused" : "Nook"
        )
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
