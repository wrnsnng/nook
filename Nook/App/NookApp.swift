import SwiftUI

@main
struct NookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel.shared
    @StateObject private var updater = NookUpdateController()
    @StateObject private var shortcuts = ShortcutStore.shared

    var body: some Scene {
        MenuBarExtra {
            StatusMenuView()
                .environmentObject(updater)
                .environmentObject(shortcuts)
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
                .environmentObject(appModel.personalNotesDraft)
                .environmentObject(appModel.prep)
                .environmentObject(appModel.recovery)
                .environmentObject(appModel.draftJournal)
                .environmentObject(appModel.draftRecovery)
                .environmentObject(shortcuts)
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
                    .keyboardShortcut(
                        shortcuts.binding(for: .pauseResumeRecording)
                            .keyEquivalent,
                        modifiers: shortcuts.binding(for: .pauseResumeRecording)
                            .eventModifiers
                    )
                    .disabled(appModel.meeting.pauseTransitionInFlight)

                    Button("Finish Meeting") {
                        appModel.meeting.stopRecording()
                    }
                    .keyboardShortcut(
                        shortcuts.binding(for: .finishMeeting).keyEquivalent,
                        modifiers: shortcuts.binding(for: .finishMeeting)
                            .eventModifiers
                    )
                    .disabled(appModel.meeting.pauseTransitionInFlight)
                } else {
                    Button("Start Recording") {
                        appModel.meeting.startManualMeeting()
                    }
                    .keyboardShortcut(
                        shortcuts.binding(for: .startRecording).keyEquivalent,
                        modifiers: shortcuts.binding(for: .startRecording)
                            .eventModifiers
                    )
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
                .environmentObject(shortcuts)
                .frame(minWidth: 360, minHeight: 320)
        }
        .defaultSize(width: 440, height: 500)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))

        Settings {
            SettingsView(
                storageLocations: { directory in
                    StorageInventoryLocation.current(
                        notesDirectory: directory,
                        draftsDirectory: appModel.draftJournal.directoryURL
                    )
                },
                reviewStorageInLibrary: { appModel.openLibrary() }
            )
                .environmentObject(appModel.store)
                .environmentObject(appModel.detector)
                .environmentObject(appModel.meeting)
                .environmentObject(appModel.appearance)
                .environmentObject(appModel.dictation)
                .environmentObject(appModel.quickNote)
                .environmentObject(appModel.audioInputCheck)
                .environmentObject(appModel.calendar)
                .environmentObject(updater)
                .environmentObject(shortcuts)
                .frame(width: 620, height: 540)
        }
    }
}

/// The `MenuBarExtra` label. Every re-render of this view re-lays out the
/// status item in the system menu bar, so it must observe nothing faster
/// than phase and pause changes: the elapsed clock, which ticks once a
/// second, lives in `MenuBarRecordingClock` below and observes
/// `MeetingLiveSignals` on its own. Nothing in this view's body or its
/// computed properties may read the coordinator's `elapsed`, `audioLevel`
/// or `liveTranscript` forwarders; they do not subscribe a view to changes.
private struct NookMenuBarLabel: View {
    @EnvironmentObject private var meeting: MeetingCoordinator
    @EnvironmentObject private var updater: NookUpdateController

    var body: some View {
        HStack(spacing: 3) {
            Group {
                if meeting.phase.isRecording {
                    MenuBarRecordingClock(
                        live: meeting.live,
                        isPaused: meeting.isPaused,
                        name: buildName
                    )
                } else {
                    Image(systemName: menuBarSymbol)
                        .accessibilityLabel(idleAccessibilityLabel)
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
                    // Spoken as part of `buildName` by whichever branch is
                    // showing, so it must not also be read out on its own.
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(
            meeting.phase.isRecording
                ? (meeting.isPaused
                    ? NookPalette.warning
                    : NookPalette.danger)
                : .primary
        )
    }

    private var isOfficialBuild: Bool {
        NookBuildIdentity.permitsOfficialUpdates
    }

    private var buildName: String {
        isOfficialBuild ? "Nook" : "Nook, development build"
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

    /// The label while nothing records. The recording label depends on the
    /// elapsed clock and so is produced inside `MenuBarRecordingClock`.
    private var idleAccessibilityLabel: String {
        if let version = updater.availableVersion {
            return "\(buildName), version \(version) is ready"
        }
        return buildName
    }
}

/// The recording half of the menu bar label: state icon plus elapsed clock.
///
/// The only part of the status item that observes `MeetingLiveSignals`, so
/// its meter, caption and clock publishes land on this small view and not on
/// `NookMenuBarLabel` around it. The spoken label is assembled here too,
/// because it includes the elapsed time and would otherwise drag the parent
/// back into observing it.
private struct MenuBarRecordingClock: View {
    @ObservedObject var live: MeetingLiveSignals
    let isPaused: Bool
    /// "Nook" or "Nook, development build"; see `NookMenuBarLabel`.
    let name: String

    var body: some View {
        HStack(spacing: 5) {
            Image(
                systemName: isPaused
                    ? "pause.fill"
                    : "record.circle.fill"
            )
            .frame(width: 13)
            Text(NookElapsedTime.clock(live.elapsed))
                .font(.system(.caption, design: .monospaced))
                .monospacedDigit()
                .frame(width: elapsedWidth, alignment: .leading)
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let spoken = NookElapsedTime.spoken(live.elapsed)
        if isPaused {
            return "\(name), recording paused, \(spoken)"
        }
        return "\(name), recording, \(spoken)"
    }

    /// Fixed so the clock does not shove the menu-bar item sideways once a
    /// second, but sized to the format actually on screen. At an hour the
    /// string grows to "1:05:23" and the old single width clipped it.
    private var elapsedWidth: CGFloat {
        live.elapsed >= 3_600 ? 56 : 38
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
