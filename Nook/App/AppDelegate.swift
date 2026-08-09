import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationIcon()
        NSApp.setActivationPolicy(.accessory)

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--audit-dark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }

        let auditLive = ProcessInfo.processInfo.arguments.contains("--audit-live")
        let auditSummary = ProcessInfo.processInfo.arguments.contains("--audit-summary")
        let auditNotes = ProcessInfo.processInfo.arguments.contains("--audit-notes")
        if auditLive || auditSummary || auditNotes {
            let transcript = LiveTranscriptState(
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
                        text: "Exactly. The top panel can hold the live moment while the library stays calm.",
                        source: .microphone
                    ),
                    TranscriptSegment(
                        startTime: 52,
                        duration: 8,
                        text: "Let’s keep the motion restrained and make the words the most important thing.",
                        source: .system
                    )
                ],
                meetingPartial: "The live captions should feel immediate, almost like",
                latestSource: .system,
                revision: 12
            )
            let mode: MeetingPanelMode = auditSummary
                ? .summary
                : (auditNotes ? .notes : .transcript)
            AppModel.shared.meeting.setPreviewState(
                phase: .recording(title: "Weekly product review", startedAt: Date().addingTimeInterval(-77)),
                elapsed: 77,
                liveTranscript: transcript,
                audioLevel: 0.48,
                panelMode: mode,
                liveInsights: auditSummary
                    ? MeetingInsights(
                        title: "Weekly product review",
                        summary: "The team is shaping a calm meeting workspace that keeps live information close to the camera without taking over the screen.",
                        keyPoints: [
                            "Keep spoken words visually primary.",
                            "Use restrained motion between views.",
                            "Keep the library quiet and easy to review."
                        ],
                        decisions: ["Use one workspace for transcript, summary, and notes."],
                        actionItems: ["Refine the transition timing before Friday."]
                    )
                    : nil,
                liveNotes: auditNotes
                    ? "Ask Ana to test the meeting prompt.\nRevisit the transition timing before Friday."
                    : nil
            )
            AppModel.shared.meeting.expandTopPanel()
            AppModel.shared.panel.show()
        }

        if ProcessInfo.processInfo.arguments.contains("--audit-failure") {
            AppModel.shared.meeting.setPreviewState(
                phase: .failed(
                    "Screen & System Audio Recording permission is required. Enable Nook in Privacy & Security, then try again."
                ),
                elapsed: 0,
                liveTranscript: .empty,
                audioLevel: 0
            )
            AppModel.shared.panel.show()
        }

        if ProcessInfo.processInfo.arguments.contains("--audit-detected") {
            AppModel.shared.meeting.setPreviewState(
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
            AppModel.shared.panel.show()
        }

        if ProcessInfo.processInfo.arguments.contains("--audit-processing") {
            AppModel.shared.meeting.setPreviewState(
                phase: .processing(.summarizing),
                elapsed: 77,
                liveTranscript: .empty,
                audioLevel: 0
            )
            AppModel.shared.panel.show()
        }

        if ProcessInfo.processInfo.arguments.contains("--audit-completed") {
            AppModel.shared.meeting.setPreviewState(
                phase: .completed("Weekly product review"),
                elapsed: 77,
                liveTranscript: .empty,
                audioLevel: 0
            )
            AppModel.shared.panel.show()
        }

        if ProcessInfo.processInfo.arguments.contains("--audit-library") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                AppModel.shared.openLibrary()
            }
        }

        if ProcessInfo.processInfo.arguments.contains("--audit-welcome") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                AppModel.shared.openIntroduction()
            }
        }

        if ProcessInfo.processInfo.arguments.contains("--smoke-test-recording") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                AppModel.shared.meeting.startManualMeeting()
            }
        }
        #endif
    }

    /// Launch Services may preserve artwork from an older build for a stable
    /// bundle identifier. Setting the packaged cobalt master explicitly keeps
    /// the Dock and app switcher in sync immediately after an OTA update.
    private func installApplicationIcon() {
        guard
            let url = Bundle.main.url(
                forResource: "NookIconSource-Cobalt",
                withExtension: "png"
            ),
            let image = NSImage(contentsOf: url)
        else {
            return
        }
        NSApp.applicationIconImage = image
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.detector.stop()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            AppModel.shared.openLibrary()
        }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu(title: "Nook")
        let model = AppModel.shared

        if model.meeting.phase.isRecording {
            let pause = NSMenuItem(
                title: model.meeting.isPaused
                    ? "Resume Recording"
                    : "Pause Recording",
                action: #selector(togglePauseFromDock),
                keyEquivalent: ""
            )
            pause.target = self
            pause.image = NSImage(
                systemSymbolName: model.meeting.isPaused
                    ? "play.fill"
                    : "pause.fill",
                accessibilityDescription: nil
            )
            pause.isEnabled = !model.meeting.pauseTransitionInFlight
            menu.addItem(pause)

            let finish = NSMenuItem(
                title: "Finish Meeting",
                action: #selector(finishMeetingFromDock),
                keyEquivalent: ""
            )
            finish.target = self
            finish.image = NSImage(
                systemSymbolName: "stop.fill",
                accessibilityDescription: nil
            )
            finish.isEnabled = !model.meeting.pauseTransitionInFlight
            menu.addItem(finish)
        } else {
            let record = NSMenuItem(
                title: "Start Recording",
                action: #selector(startRecordingFromDock),
                keyEquivalent: ""
            )
            record.target = self
            record.image = NSImage(
                systemSymbolName: "waveform.badge.mic",
                accessibilityDescription: nil
            )
            menu.addItem(record)
        }

        menu.addItem(.separator())

        let library = NSMenuItem(
            title: "Open Meeting Library",
            action: #selector(openLibraryFromDock),
            keyEquivalent: ""
        )
        library.target = self
        library.image = NSImage(
            systemSymbolName: "books.vertical",
            accessibilityDescription: nil
        )
        menu.addItem(library)

        if let latest = model.store.notes.first {
            let latestItem = NSMenuItem(
                title: "Open “\(latest.title)”",
                action: #selector(openLatestMeetingFromDock),
                keyEquivalent: ""
            )
            latestItem.target = self
            latestItem.image = NSImage(
                systemSymbolName: "clock.arrow.circlepath",
                accessibilityDescription: nil
            )
            menu.addItem(latestItem)
        }

        return menu
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        if terminationTask != nil {
            return .terminateLater
        }
        guard prepareMarkdownForTermination(model: model, sender: sender) else {
            return .terminateCancel
        }

        let terminationState = model.meeting.terminationState
        guard terminationState != .inactive else {
            return .terminateNow
        }
        guard confirmMeetingTermination(terminationState, sender: sender) else {
            return .terminateCancel
        }

        terminationTask = Task { @MainActor [weak self, weak sender] in
            let ready = await model.meeting.prepareForApplicationTermination()
            self?.terminationTask = nil
            if !ready {
                self?.showMeetingTerminationFailure()
            }
            sender?.reply(toApplicationShouldTerminate: ready)
        }
        return .terminateLater
    }

    private func prepareMarkdownForTermination(
        model: AppModel,
        sender: NSApplication
    ) -> Bool {
        let draft = model.markdownDraft
        guard draft.hasChanges else { return true }

        sender.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Save your Markdown changes before quitting?"
        alert.informativeText = "Your edit is still in Nook and hasn’t been written to disk."
        alert.addButton(withTitle: "Save and Quit")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard Changes")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard let noteID = draft.noteID,
                  let note = model.store.notes.first(where: { $0.id == noteID })
            else {
                showSaveFailure("The original note is no longer in the current notes folder.")
                return false
            }
            do {
                try draft.save(note: note, store: model.store)
                return true
            } catch {
                showSaveFailure(error.localizedDescription)
                return false
            }
        case .alertThirdButtonReturn:
            draft.discardChanges()
            return true
        default:
            return false
        }
    }

    private func confirmMeetingTermination(
        _ state: MeetingTerminationState,
        sender: NSApplication
    ) -> Bool {
        sender.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        switch state {
        case .recording:
            alert.messageText = "Finish this meeting before quitting?"
            alert.informativeText = "Nook will stop recording, create the local meeting note, remove temporary capture files, and then quit."
            alert.addButton(withTitle: "Finish and Quit")
        case .processing:
            alert.messageText = "Nook is still creating your meeting note"
            alert.informativeText = "Nook will finish its local processing, remove temporary capture files, and then quit."
            alert.addButton(withTitle: "Wait and Quit")
        case .inactive:
            return true
        }
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showMeetingTerminationFailure() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Nook couldn’t finish the meeting before quitting"
        alert.informativeText = "Nook will stay open so you can review the error. It removed temporary recording files where possible and will identify any file that needs manual cleanup."
        alert.addButton(withTitle: "Keep Nook Open")
        alert.runModal()
    }

    private func showSaveFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Nook couldn’t save that edit"
        alert.informativeText = "\(message)\n\nNook will stay open so the text is not lost."
        alert.addButton(withTitle: "Keep Nook Open")
        alert.runModal()
    }

    @objc private func startRecordingFromDock() {
        AppModel.shared.meeting.startManualMeeting()
    }

    @objc private func togglePauseFromDock() {
        AppModel.shared.meeting.togglePause()
    }

    @objc private func finishMeetingFromDock() {
        AppModel.shared.meeting.stopRecording()
    }

    @objc private func openLibraryFromDock() {
        AppModel.shared.openLibrary()
    }

    @objc private func openLatestMeetingFromDock() {
        AppModel.shared.openLatestMeeting()
    }
}
