import AppKit
import SwiftUI

@main
struct SnapshotRenderer {
    @MainActor
    static func main() throws {
        let arguments = CommandLine.arguments
        guard (2...4).contains(arguments.count),
              arguments.count < 4 || arguments[3] == "--interactive" else {
            FileHandle.standardError.write(
                Data("Usage: NookSnapshot <output.png> [library|library-light|library-compact|welcome-light|welcome-dark|welcome-permission-light|welcome-permission-dark|welcome-ready-light|welcome-ready-dark|welcome-microphone-light|welcome-microphone-dark|welcome-speech-light|welcome-speech-dark|welcome-calendar-light|welcome-calendar-dark|welcome-dictation-light|welcome-dictation-dark|detail-transcript-light|detail-transcript-dark|detail-transcript-partial-light|detail-transcript-partial-dark|detail-transcript-no-matches-light|detail-transcript-no-matches-dark|detail-markdown-light|detail-markdown-dark|detail-markdown-conflict-light|detail-markdown-conflict-dark|detail-notes-light|detail-notes-dark|copy-failure-long-light|copy-failure-long-dark|copy-failure-pathological-light|copy-failure-pathological-dark|settings-about-light|settings-about-dark|settings-general-light|settings-general-dark|settings-listening-light|settings-listening-dark|settings-dictation-light|settings-dictation-dark|settings-assistant-unavailable-light|settings-assistant-unavailable-dark|settings-keyboard-light|settings-keyboard-dark|settings-privacy-light|settings-privacy-dark|settings-updates-light|settings-updates-dark|storage-light|storage-dark|storage-long-light|storage-long-dark|quick-note-light|quick-note-dark|quick-note-filled-light|quick-note-filled-dark|quick-note-codex-light|quick-note-codex-dark|quick-note-conflict-light|quick-note-conflict-dark|quick-note-conflict-codex-light|quick-note-conflict-codex-dark|quick-note-assistant-unavailable-light|quick-note-assistant-unavailable-dark|quick-note-assistant-running-light|quick-note-assistant-running-dark|quick-note-assistant-stopping-light|quick-note-assistant-stopping-dark|quick-note-filing-copy-retained-light|quick-note-filing-copy-retained-dark|draft-recovery-light|draft-recovery-dark|draft-recovery-minimum-light|draft-recovery-long-light|draft-recovery-invalid-light|draft-recovery-stale-light|draft-recovery-unavailable-light|recovery-section-light|recovery-section-dark|recovery-section-minimum-light|recovery-section-failure-light|recovery-section-failure-dark|recovery-section-library-light|library-draft-recovery-light|library-draft-recovery-dark|prep-light|prep-dark|ask-light|ask-dark|ask-answer-light|ask-answer-dark|ask-refusal-light|ask-refusal-dark|ask-long-light|ask-long-dark|ask-long-question-light|ask-long-question-dark|palette-light|palette-dark|floating-notes-light|floating-notes-dark|library-recording-light|library-recording-dark|live-follow-light|live-follow-dark|live|notch|external-panel|panel-compact-idle|panel-compact-flagged|panel-hidden-recording|panel-hidden-paused|summary-light|summary-dark|summary-regeneration-light|summary-regeneration-dark|notes-light|notes-dark|detected-light|detected-dark|detected-compact-light|detected-compact-dark|processing-light|processing-dark|completed-light|completed-dark|failure-light|failure-dark] [--interactive]\n".utf8)
            )
            Foundation.exit(64)
        }
        let mode = arguments.count >= 3 ? arguments[2] : "library"
        let isInteractive = arguments.count == 4
        let isCopyFailureFixture = [
            "copy-failure-long-light", "copy-failure-long-dark",
            "copy-failure-pathological-light", "copy-failure-pathological-dark"
        ].contains(mode)
        let isLiveFollowFixture = ["live-follow-light", "live-follow-dark"].contains(mode)
        let staticPanelModes: Set<String> = [
            "panel-compact-idle", "panel-compact-flagged",
            "panel-hidden-recording", "panel-hidden-paused"
        ]
        let isAssistantFixture = mode.hasPrefix("quick-note-assistant-")
            || mode.hasPrefix("settings-assistant-")
        let isAssistantUnavailable = isAssistantFixture && mode.contains("unavailable")
        let isFilingCopyFixture = [
            "quick-note-filing-copy-retained-light", "quick-note-filing-copy-retained-dark"
        ].contains(mode)
        let assistantFixtureText = "Synthetic planning note. Keep these words while reviewing the assistant controls."
        // Live acceptance deliberately exposes only recovery, storage, and
        // synthetic notice/replay controls. Other app surfaces contain capture
        // and assistant commands that have no place in a synthetic UI harness.
        guard !isInteractive || mode.hasPrefix("draft-recovery")
            || mode.hasPrefix("recovery-section") || mode.hasPrefix("storage-")
            || isCopyFailureFixture || isLiveFollowFixture else {
            FileHandle.standardError.write(Data(
                "Interactive acceptance supports draft-recovery, recovery-section, storage, listed copy-failure modes, and live-follow-light/dark only.\n".utf8
            ))
            Foundation.exit(64)
        }
        let snapshotColorScheme: ColorScheme = mode.hasSuffix("-light")
            ? .light
            : .dark

        let app = NSApplication.shared
        app.setActivationPolicy(isInteractive ? .regular : .prohibited)

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

        // Set the first directory before constructing the store. Its initial
        // reload must never visit the user's configured notes folder, even
        // briefly before the fixture directory replaces it.
        var snapshotDefaults: [String: Any] = [
            "storageDirectory": fixtureDirectory.path,
            "quickNoteEngine": mode.contains("codex") ? "codex" : "onDevice",
            "quickNoteContinuous": false,
            "quickNoteConsent.codex.v2": true
        ]
        if isAssistantFixture {
            // The new fixtures own their assistant choice and consent in a
            // separate suite. Do not let argument-domain values override it.
            snapshotDefaults.removeValue(forKey: "quickNoteEngine")
            snapshotDefaults.removeValue(forKey: "quickNoteConsent.codex.v2")
            snapshotDefaults["dictationEnabled"] = false
        }
        if isFilingCopyFixture {
            snapshotDefaults["dictationEnabled"] = false
            snapshotDefaults["quickNoteConsent.codex.v2"] = false
        }
        UserDefaults.standard.setVolatileDomain(snapshotDefaults, forName: UserDefaults.argumentDomain)

        let filingFiles = isFilingCopyFixture
            ? SnapshotFilingFileManager(directory: fixtureDirectory) : nil
        let store = MarkdownStore(fileManager: filingFiles.map { $0 as FileManager } ?? fileManager)
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
        let assistantDefaultsName = "NookSnapshotAssistant-\(UUID().uuidString)"
        let assistantDefaults: UserDefaults?
        if isAssistantFixture {
            guard let defaults = UserDefaults(suiteName: assistantDefaultsName) else {
                throw SnapshotError.fixtureValidationFailed
            }
            defaults.set(isAssistantUnavailable ? "onDevice" : "codex", forKey: "quickNoteEngine")
            defaults.set(!isAssistantUnavailable, forKey: "quickNoteConsent.codex.v2")
            defaults.set(false, forKey: "quickNoteContinuous")
            assistantDefaults = defaults
        } else {
            assistantDefaults = nil
        }
        defer { assistantDefaults?.removePersistentDomain(forName: assistantDefaultsName) }
        let assistantGate = isAssistantFixture ? SnapshotAssistantGate() : nil
        let assistantRun: (@Sendable (NoteAction, String, NoteAssistantEngine) async throws -> String)?
        if let assistantGate {
            assistantRun = { action, text, engine in
                await assistantGate.run(action: action, text: text, engine: engine)
            }
        } else if isFilingCopyFixture {
            assistantRun = { _, _, _ in throw SnapshotError.fixtureValidationFailed }
        } else {
            assistantRun = nil
        }
        let fixtureEngines: [NoteAssistantEngine] = isAssistantUnavailable
            ? [.codex] : [.onDevice, .codex]
        let openFilingLibrary: (@MainActor () -> Void)?
        if isFilingCopyFixture {
            openFilingLibrary = {}
        } else {
            openFilingLibrary = nil
        }
        let quickNote = QuickNoteController(
            store: store,
            assistantRun: assistantRun,
            availableEngines: { fixtureEngines },
            defaults: assistantDefaults ?? .standard,
            openFilingLibrary: openFilingLibrary
        )
        var assistantTask: Task<Void, Never>?
        var assistantWasReleased = false
        defer {
            // Release the controlled, cancellation-resistant stub even when
            // an earlier fixture assertion or image encoding throws.
            if !assistantWasReleased {
                assistantGate?.release()
                if let assistantTask { try? completeSnapshotTask(assistantTask) }
            }
        }
        var askFixtureSession: LibraryAskSession?
        let engineRefresh = quickNote.refreshEngines()
        if isAssistantFixture {
            try completeSnapshotTask(engineRefresh)
            quickNote.text = assistantFixtureText
            if !isAssistantUnavailable {
                guard let task = quickNote.run(.summarize), let assistantGate else {
                    throw SnapshotError.fixtureValidationFailed
                }
                assistantTask = task
                try waitForSnapshotCondition { assistantGate.didStart }
                if mode.contains("stopping") { quickNote.selectEngine(.onDevice) }
            }
            try validateAssistantFixture(
                mode: mode, controller: quickNote, gate: assistantGate,
                originalText: assistantFixtureText
            )
        }
        let recovery = RecordingRecovery(store: store)
        let draftJournal = DraftJournal(
            directoryURL: fixtureDirectory.appendingPathComponent("Drafts", isDirectory: true)
        )
        let draftRecovery = DraftRecoveryController(journal: draftJournal, store: store)
        let corruptRecoveryFileNames = [
            "00000000-0000-4000-8000-000000000001.json",
            "SyntheticRecoveryCheckpointWithALongUnbrokenFilenameForWrappingReview.json"
        ]
        var recoveredDraft = DraftCheckpoint(
            kind: .personalNotes,
            libraryPath: "/Users/example/Documents/Nook",
            originalFilePath: "/Users/example/Documents/Nook/design-review.md",
            noteID: UUID(),
            title: "Design review follow-up",
            text: "Ask Ana to test the new meeting prompt.\n\n- [ ] Check the shortcut in a full-screen app\n- [ ] Review the transcript with VoiceOver\n\nKeep the recording consent visible before capture starts.",
            baseline: "Ask Ana to test the new meeting prompt.",
            createdAt: Date(timeIntervalSince1970: 1_788_100_000),
            checkpointedAt: Date(timeIntervalSince1970: 1_788_100_300),
            sessionID: UUID()
        )
        if mode.contains("long") {
            recoveredDraft.title = "Design review follow-up for the international product research and accessibility programme"
            recoveredDraft.libraryPath = "/Volumes/Synthetic research archive/International product programme/Working documents and notes/2026 research synthesis and accessibility acceptance/Nook"
            recoveredDraft.originalFilePath = recoveredDraft.libraryPath + "/Design review with a long descriptive filename and an unavailable original volume.md"
            recoveredDraft.text = String(repeating: "An intentionally long synthetic draft preserves each original word, blank line, and Unicode character. Café 👩🏽‍💻\n\n", count: 1_200)
        }
        if mode.contains("invalid") {
            recoveredDraft.kind = .markdown
            recoveredDraft.text = "---\n---\nid: \(UUID().uuidString)\nstarted: 2026-08-31T00:00:00Z\nended: 2026-08-31T00:05:00Z\n---\n\n# Unfinished raw source\n\nKeep these exact words, even though the metadata is incomplete.\n"
        }
        if (mode.contains("draft-recovery") || mode.hasPrefix("recovery-section"))
            && !mode.contains("unavailable") {
            try draftJournal.persistSynchronously(recoveredDraft)
            if mode.hasPrefix("recovery-section") {
                for index in 2...5 {
                    var next = recoveredDraft
                    next.id = UUID()
                    next.noteID = UUID()
                    next.title = "Synthetic unfinished draft \(index)"
                    next.kind = index.isMultiple(of: 2) ? .quickNote : .markdown
                    if next.kind == .markdown {
                        next.text = MarkdownCodec.encode(fixtures[0])
                    }
                    try draftJournal.persistSynchronously(next)
                }
            }
            if mode.contains("stale") {
                var changed = recoveredDraft
                changed.text += "\nA newer checkpoint contains this additional synthetic line."
                try draftJournal.persistSynchronously(changed)
            }
            if mode.contains("failure") {
                for filename in corruptRecoveryFileNames {
                    let corruptFile = draftJournal.directoryURL.appendingPathComponent(filename)
                    try Data("This synthetic recovery file is deliberately incomplete.".utf8)
                        .write(to: corruptFile)
                    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: corruptFile.path)
                }
            }
        }
        if mode.contains("draft-recovery") || mode.hasPrefix("recovery-section") {
            // A large selectable Text can occupy the first render pass long
            // enough to exhaust the post-layout settle interval. Publish the
            // synthetic journal first so the capture never mistakes a pending
            // scan for an unavailable recovery.
            try prepareRecoveryJournal(draftJournal)
            let expectedCount = mode.contains("unavailable") ? 0
                : (mode.hasPrefix("recovery-section") ? 5 : 1)
            guard draftJournal.recoveredDrafts.count == expectedCount else {
                throw SnapshotError.fixtureValidationFailed
            }
            if mode.contains("failure") {
                guard Set(draftJournal.issues.map { $0.fileURL.lastPathComponent })
                        == Set(corruptRecoveryFileNames),
                      Set(draftJournal.issues.map(\.message)).count == 1 else {
                    throw SnapshotError.fixtureValidationFailed
                }
            }
        }
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
        var validateConflictFixture: (@MainActor () throws -> Void)?
        var validateFilingFixture: (@MainActor () throws -> Void)?
        switch mode {
        case "copy-failure-long-light", "copy-failure-long-dark",
             "copy-failure-pathological-light", "copy-failure-pathological-dark":
            canvasSize = CGSize(width: 560, height: 420)
            let filename = "Synthetic international product research, meeting decisions, notes and accessibility acceptance, unresolved follow-up actions, and archived source review.md"
            let error = CocoaError(.fileReadNoPermission, userInfo: [
                NSFilePathErrorKey: fixtureDirectory.appendingPathComponent(filename).path
            ])
            let message = mode.contains("pathological")
                ? String(repeating: error.localizedDescription + "\n\n", count: 32)
                : error.localizedDescription
            print("Failure banner fixture full message: \(message)")
            let longMessage = String(repeating: error.localizedDescription + "\n\n", count: 32)
                + "End of the synthetic long error. All message text remains available."
            content = AnyView(
                CopyNoticeSnapshotHost(
                    initialMessage: mode.contains("pathological") ? longMessage : message,
                    longMessage: longMessage
                )
                .frame(width: canvasSize.width, height: canvasSize.height)
                .environment(\.colorScheme, snapshotColorScheme)
                .transaction { $0.disablesAnimations = true }
            )
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
            var detailNote = roundTripped
            let hasNoMatchingTranscript = mode.contains("no-matches")
            if mode.contains("partial") || hasNoMatchingTranscript {
                detailNote.audioStart = 14
                detailNote = try store.save(detailNote)
                // A readable placeholder reveals transport layout without
                // recording, decoding, or playing any real audio.
                let recordings = store.recordingsDirectory()
                try Data().write(to: recordings.appendingPathComponent(
                    "\(detailNote.id.uuidString).m4a"
                ))
            }
            let hasSaveConflict = mode.contains("conflict")
            canvasSize = hasSaveConflict
                ? CGSize(width: 900, height: 580)
                : (hasNoMatchingTranscript
                    ? CGSize(width: 560, height: 580)
                    : CGSize(width: 1_100, height: 700))
            let initialTab: DetailTab = mode.contains("transcript")
                ? .transcript
                : (mode.contains("markdown") ? .markdown : .notes)
            meeting.setPreviewState(phase: .idle, elapsed: 0, liveTranscript: .empty, audioLevel: 0)
            if hasSaveConflict {
                validateConflictFixture = try prepareMarkdownConflict(
                    note: detailNote, draft: markdownDraft, store: store
                )
            }
            if hasNoMatchingTranscript {
                guard AudioPlaybackController.audioURL(for: detailNote) != nil else {
                    throw SnapshotError.fixtureValidationFailed
                }
                print("Transcript fixture: kept-audio metadata, zero matching passages, no playback started.")
            }
            content = AnyView(
                HStack(spacing: 0) {
                    if hasSaveConflict {
                        // Reserve the Library's 304pt ideal sidebar without
                        // adding interactive app commands or relying on an
                        // offscreen NSSplitView to pick its initial width.
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Library").font(.title2.weight(.semibold))
                            Text("Synthetic save conflict")
                                .font(.headline)
                            Text("900 × 580 window\n304pt sidebar\n595pt detail after divider")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(20)
                        .frame(width: 304)
                        .frame(maxHeight: .infinity)
                        .background(Color(nsColor: .windowBackgroundColor))
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor))
                            .frame(width: 1)
                    }
                    MeetingDetailView(
                        note: detailNote,
                        initialTab: initialTab,
                        initialTranscriptSearch: hasNoMatchingTranscript ? "This phrase is absent" : ""
                    )
                    .frame(width: hasSaveConflict ? 595 : canvasSize.width)
                }
                .environmentObject(store)
                .environmentObject(meeting)
                .environmentObject(markdownDraft)
                .environmentObject(personalNotesDraft)
                .frame(width: canvasSize.width, height: canvasSize.height)
                .environment(\.colorScheme, snapshotColorScheme)
                .transaction { $0.disablesAnimations = true }
            )
        case _ where mode.hasPrefix("storage-"):
            canvasSize = CGSize(width: 620, height: 540)
            let storageFixture = try StorageSnapshotFixture.make(
                in: fixtureDirectory, usesLongPaths: mode.contains("long")
            )
            print("Storage fixture: \(storageFixture.root.path)")
            print(storageFixture.expectations)
            content = AnyView(
                StorageSnapshotHost(fixture: storageFixture)
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, snapshotColorScheme)
                    .transaction { $0.disablesAnimations = true }
            )
        case _ where mode.hasPrefix("settings"):
            canvasSize = CGSize(width: 620, height: 540)
            let pane: SettingsPane
            if mode.contains("about") { pane = .about }
            else if mode.contains("dictation") || mode.contains("assistant") { pane = .dictation }
            else if mode.contains("keyboard") { pane = .keyboard }
            else if mode.contains("privacy") { pane = .privacy }
            else if mode.contains("updates") { pane = .updates }
            else if mode.contains("listening") { pane = .listening }
            else { pane = .general }
            meeting.setPreviewState(phase: .idle, elapsed: 0, liveTranscript: .empty, audioLevel: 0)
            content = AnyView(
                SettingsView(
                    initialPane: pane,
                    storageLocations: { directory in
                        // Resolve only the snapshot's owned temporary fixture.
                        // Foundation can alias /private/var back through /var,
                        // which the inventory correctly refuses to traverse.
                        let resolved = realpath(directory.path, nil)
                        defer { free(resolved) }
                        let physical = resolved.map { URL(fileURLWithPath: String(cString: $0)) } ?? directory
                        let resolvedDrafts = realpath(draftJournal.directoryURL.path, nil)
                        defer { free(resolvedDrafts) }
                        let physicalDrafts = resolvedDrafts.map { URL(fileURLWithPath: String(cString: $0)) }
                            ?? draftJournal.directoryURL
                        return [
                            StorageInventoryLocation(id: .notes, url: physical, scope: .markdownFiles),
                            StorageInventoryLocation(id: .interruptedSaves, url: physical, scope: .interruptedSaveFiles),
                            StorageInventoryLocation(id: .recordings, url: physical.appendingPathComponent(".recordings"), scope: .directFiles),
                            StorageInventoryLocation(id: .drafts, url: physicalDrafts, scope: .directFiles),
                            StorageInventoryLocation(id: .searchCache, url: physical.appendingPathComponent("cache/chunks.json"), scope: .file),
                            StorageInventoryLocation(id: .appCache, url: physical.appendingPathComponent("cache"), scope: .directoryTree),
                            StorageInventoryLocation(id: .eventLog, url: physical.appendingPathComponent("events.log"), scope: .file),
                            StorageInventoryLocation(id: .developerLog, url: physical.appendingPathComponent("developer.log"), scope: .file)
                        ]
                    },
                    reviewStorageInLibrary: {}
                )
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
        case _ where mode.hasPrefix("draft-recovery"):
            canvasSize = mode.contains("minimum")
                ? CGSize(width: 590, height: 580)
                : (mode.contains("long") || mode.contains("invalid") || mode.contains("stale") || mode.contains("unavailable")
                    ? CGSize(width: 590, height: 620)
                    : CGSize(width: 760, height: 740))
            content = AnyView(
                DraftRecoveryView(checkpoint: recoveredDraft, controller: draftRecovery)
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, snapshotColorScheme)
                    .transaction { $0.disablesAnimations = true }
            )
        case _ where mode.hasPrefix("recovery-section"):
            canvasSize = CGSize(width: mode.contains("library") ? 900 : (mode.contains("minimum") ? 260 : 360), height: 580)
            let recoveryList = List {
                DraftRecoverySection(controller: draftRecovery, journal: draftJournal)
            }
            .listStyle(.sidebar)
            content = AnyView(
                Group {
                    if mode.contains("library") {
                        NavigationSplitView {
                            recoveryList
                                .navigationSplitViewColumnWidth(min: 260, ideal: 304, max: 380)
                        } detail: {
                            ContentUnavailableView(
                                "Synthetic recovery acceptance",
                                systemImage: "doc.badge.clock",
                                description: Text("Review a recovered draft in the sidebar. These fixtures cannot start recording or invoke an assistant.")
                            )
                        }
                    } else {
                        recoveryList
                    }
                }
                .frame(width: canvasSize.width, height: canvasSize.height)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, snapshotColorScheme)
                .transaction { $0.disablesAnimations = true }
            )
        case "quick-note-light", "quick-note-dark", "quick-note-filled-light", "quick-note-filled-dark", "quick-note-codex-light", "quick-note-codex-dark",
             "quick-note-conflict-light", "quick-note-conflict-dark",
             "quick-note-conflict-codex-light", "quick-note-conflict-codex-dark",
             "quick-note-assistant-unavailable-light", "quick-note-assistant-unavailable-dark",
             "quick-note-assistant-running-light", "quick-note-assistant-running-dark",
             "quick-note-assistant-stopping-light", "quick-note-assistant-stopping-dark",
             "quick-note-filing-copy-retained-light", "quick-note-filing-copy-retained-dark":
            canvasSize = mode.contains("conflict") || isAssistantFixture || isFilingCopyFixture
                ? CGSize(width: 380, height: 240)
                : CGSize(width: 460, height: 340)
            if isFilingCopyFixture {
                guard let filingFiles else { throw SnapshotError.fixtureValidationFailed }
                validateFilingFixture = try prepareQuickNoteFilingCopy(
                    quickNote, target: roundTripped, store: store, files: filingFiles
                )
            } else if mode.contains("conflict") {
                validateConflictFixture = try prepareQuickNoteConflict(quickNote)
            } else if mode.hasPrefix("quick-note-filled") || mode.contains("codex") {
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
        case "summary-regeneration-light", "summary-regeneration-dark":
            canvasSize = CGSize(width: 380, height: 180)
            content = AnyView(
                SummaryRegenerationProgressCard(
                    stage: .condensing(pass: 12, part: 9_876, total: 10_000),
                    onCancel: {}
                )
                    .padding(16)
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .background(Color(nsColor: .windowBackgroundColor))
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
        case "ask-light", "ask-dark", "ask-answer-light", "ask-answer-dark",
             "ask-refusal-light", "ask-refusal-dark", "ask-long-light", "ask-long-dark",
             "ask-long-question-light", "ask-long-question-dark":
            canvasSize = CGSize(width: 560, height: mode.contains("long-question") ? 380 : 420)
            let session: LibraryAskSession
            if mode.contains("answer") || mode.contains("refusal") || mode.contains("long") {
                let note = fixtures[0]
                let isRefusal = mode.contains("refusal")
                let passage = "Prototype the three-step onboarding for Friday’s review."
                let response = LibraryAskSession.Response(
                    answer: LibraryAnswer(
                        text: mode.contains("long")
                            ? String(repeating: passage + "\n\n", count: 24)
                            : passage,
                        citations: isRefusal ? [] : [LibraryCitation(
                            number: 1,
                            chunk: LibraryChunk(
                                noteID: note.id, noteTitle: note.title,
                                startedAt: note.startedAt, label: "Decision", text: passage
                            )
                        )],
                        refusedReason: isRefusal
                            ? "The notes do not contain enough evidence to answer this question. Try naming a meeting or a decision that was discussed."
                            : nil
                    ),
                    errorMessage: isRefusal ? "The synthetic response deliberately contains no supporting passage." : nil
                )
                // Only the presentation is under test. No service, retrieval
                // cache or model is created by these synthetic answer fixtures.
                let isLongQuestion = mode.contains("long-question")
                session = LibraryAskSession(answerer: { _, _ in
                    if isLongQuestion {
                        try? await Task.sleep(for: .seconds(30))
                    }
                    return response
                })
                session.question = isLongQuestion
                    ? String(repeating: "Which onboarding decisions need another review, and which preparations should stay local to this synthetic notebook? ", count: 20)
                    : "What did we decide about onboarding?"
                session.ask(notes: store.notes)
                session.question = "What should we review next?"
                askFixtureSession = session
            } else {
                session = LibraryAskSession()
            }
            content = AnyView(
                LibraryAskView(notes: store.notes, onSelectNote: { _ in }, onClose: {}, session: session)
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
                        .environmentObject(draftJournal)
                        .environmentObject(draftRecovery)
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
                    .environmentObject(draftJournal)
                    .environmentObject(draftRecovery)
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .environment(\.colorScheme, snapshotColorScheme)
                    .transaction { $0.disablesAnimations = true }
            )
        case "live-follow-light", "live-follow-dark":
            canvasSize = CGSize(width: 900, height: 650)
            let replay = LiveFollowSnapshotHost.seededTranscript(count: 60)
            LiveFollowSnapshotHost.publish(replay, paused: false, to: meeting)
            content = AnyView(
                LiveFollowSnapshotHost(meeting: meeting, transcript: replay)
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .environment(\.colorScheme, snapshotColorScheme)
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
             "panel-compact-idle", "panel-compact-flagged",
             "panel-hidden-recording", "panel-hidden-paused",
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
                    .environmentObject(draftJournal)
                    .environmentObject(draftRecovery)
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .environment(\.colorScheme, snapshotColorScheme)
                    .transaction { $0.disablesAnimations = true }
            )
        }

        let notchModes: Set<String> = ["notch","external-panel","summary-light","summary-dark","notes-light","notes-dark","detected-light","detected-dark","detected-compact-light","detected-compact-dark","processing-light","processing-dark","completed-light","completed-dark","failure-light","failure-dark","live"]
        if notchModes.contains(mode) || staticPanelModes.contains(mode) {
            meeting.showLiveCaptions = mode != "external-panel" && !staticPanelModes.contains(mode)
            switch mode {
            case "panel-compact-idle", "panel-compact-flagged",
                 "panel-hidden-recording", "panel-hidden-paused":
                meeting.setPreviewState(
                    phase: .recording(
                        title: "Synthetic panel status review",
                        startedAt: Date().addingTimeInterval(-13 * 60 - 42)
                    ),
                    elapsed: 13 * 60 + 42,
                    liveTranscript: transcriptState,
                    audioLevel: 0,
                    panelMode: .transcript,
                    isPaused: mode == "panel-hidden-paused"
                )
                if mode.hasPrefix("panel-hidden") {
                    meeting.hideTopPanel()
                }
                if mode == "panel-compact-flagged" {
                    // The preview marks only an in-memory moment. No capture
                    // or provider work is started, and this mode is static-only.
                    meeting.flagMoment()
                }
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
            styleMask: isInteractive ? [.titled, .closable, .resizable] : [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = mode.hasPrefix("storage-") || isCopyFailureFixture || isLiveFollowFixture
            ? "Nook Acceptance, Synthetic Data"
            : "Nook Recovery Acceptance, Synthetic Data"
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hostingView
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        // View preparation and asynchronous store reloads must not replace
        // the refused draft or clear its actual controller error before capture.
        try validateConflictFixture?()
        try validateFilingFixture?()
        if staticPanelModes.contains(mode) {
            let expectsFlag = mode == "panel-compact-flagged"
            guard meeting.phase.isRecording,
                  !meeting.showLiveCaptions,
                  meeting.topPanelHidden == mode.hasPrefix("panel-hidden"),
                  meeting.isPaused == (mode == "panel-hidden-paused"),
                  (meeting.momentAcknowledgedAt != nil) == expectsFlag,
                  meeting.liveMoments.count == (expectsFlag ? 1 : 0) else {
                throw SnapshotError.fixtureValidationFailed
            }
        }
        if let session = askFixtureSession {
            let expectedProgress = mode.contains("long-question")
            guard session.isAnswering == expectedProgress,
                  expectedProgress || session.answer != nil,
                  session.submittedQuestion?.hasPrefix(expectedProgress ? "Which onboarding" : "What did we decide") == true,
                  session.question == "What should we review next?" else {
                throw SnapshotError.fixtureValidationFailed
            }
        }
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        guard let representation = hostingView.bitmapImageRepForCachingDisplay(
            in: hostingView.bounds
        ) else {
            throw SnapshotError.renderFailed
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        try validateFilingFixture?()
        if isAssistantFixture {
            try validateAssistantFixture(
                mode: mode, controller: quickNote, gate: assistantGate,
                originalText: assistantFixtureText
            )
            assistantGate?.release()
            if let assistantTask { try completeSnapshotTask(assistantTask) }
            assistantWasReleased = true
            guard !quickNote.isWorking, quickNote.runningEngine == nil,
                  quickNote.runningAction == nil, !quickNote.isStoppingAssistant,
                  quickNote.text.utf8.elementsEqual(assistantFixtureText.utf8) else {
                throw SnapshotError.fixtureValidationFailed
            }
            if mode.contains("stopping"), quickNote.outboundEngine != nil {
                throw SnapshotError.fixtureValidationFailed
            }
        }
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
        if mode.contains("recovery") {
            print("Recovery fixture: \(draftJournal.recoveredDrafts.count) drafts, \(draftJournal.issues.count) issues; canvas \(Int(canvasSize.width))x\(Int(canvasSize.height)); fitting \(hostingView.fittingSize)")
        }
        if mode.contains("conflict") {
            print("Conflict fixture verified: external file unchanged, local edit retained; canvas \(Int(canvasSize.width))x\(Int(canvasSize.height)); fitting \(hostingView.fittingSize)")
        }
        if isFilingCopyFixture {
            print("Filing fixture verified: target contains the words once, source copy retained, completion notice remains; canvas 380x240.")
        }
        if isInteractive {
            let appMenu = NSMenu()
            let appMenuItem = NSMenuItem()
            let commands = NSMenu()
            commands.addItem(
                withTitle: mode.hasPrefix("storage-") || isCopyFailureFixture || isLiveFollowFixture
                    ? "Quit Nook Acceptance" : "Quit Recovery Acceptance",
                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
            )
            appMenuItem.submenu = commands
            appMenu.addItem(appMenuItem)
            app.mainMenu = appMenu
            let delegate = SnapshotApplicationDelegate()
            app.delegate = delegate
            window.center()
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            withExtendedLifetime(delegate) { app.run() }
        }
    }

    @MainActor
    private static func prepareMarkdownConflict(
        note: MeetingNote, draft: MarkdownDraftController, store: MarkdownStore
    ) throws -> (@MainActor () throws -> Void) {
        guard let file = note.fileURL else { throw SnapshotError.fixtureValidationFailed }
        draft.prepare(for: note, store: store)
        let original = try Data(contentsOf: file)
        let localEdit = draft.rawMarkdown + "\n\nSynthetic local edit: keep the review checklist beside this source.\n"
        draft.rawMarkdown = localEdit
        var externalEdit = original
        externalEdit.append(Data("\n\nSynthetic external edit: another writer changed this file.\n".utf8))
        try externalEdit.write(to: file, options: .atomic)
        do {
            try draft.save(note: note, store: store)
            throw SnapshotError.fixtureValidationFailed
        } catch MarkdownStoreError.fileChangedElsewhere {
            // The controller produces the production error and retains its
            // original baseline. No snapshot-only error setter is involved.
        }
        let validate: @MainActor () throws -> Void = {
            guard draft.hasChanges,
                  draft.rawMarkdown.utf8.elementsEqual(localEdit.utf8),
                  draft.statusMessage == MarkdownStoreError.fileChangedElsewhere.localizedDescription,
                  try Data(contentsOf: file) == externalEdit else {
                throw SnapshotError.fixtureValidationFailed
            }
        }
        try validate()
        return validate
    }

    @MainActor
    private static func prepareQuickNoteConflict(
        _ controller: QuickNoteController
    ) throws -> (@MainActor () throws -> Void) {
        controller.text = "Synthetic planning note. Keep the review checklist beside the source."
        guard let saved = controller.saveIfNeeded(), let file = saved.fileURL else {
            throw SnapshotError.fixtureValidationFailed
        }
        let original = try Data(contentsOf: file)
        let localEdit = controller.text + "\n\nThese additional words are still held in the pad."
        controller.text = localEdit
        var externalEdit = original
        externalEdit.append(Data("\n\nSynthetic external edit: another writer changed this file.\n".utf8))
        try externalEdit.write(to: file, options: .atomic)
        guard controller.saveIfNeeded() == nil else { throw SnapshotError.fixtureValidationFailed }
        let validate: @MainActor () throws -> Void = {
            guard controller.hasUnsavedFailure, controller.hasUnsavedEdits,
                  controller.text.utf8.elementsEqual(localEdit.utf8),
                  controller.message?.hasSuffix(MarkdownStoreError.fileChangedElsewhere.localizedDescription) == true,
                  !controller.isWorking, !controller.isContinuous,
                  try Data(contentsOf: file) == externalEdit else {
                throw SnapshotError.fixtureValidationFailed
            }
        }
        try validate()
        return validate
    }

    @MainActor
    private static func prepareQuickNoteFilingCopy(
        _ controller: QuickNoteController, target: MeetingNote,
        store: MarkdownStore, files: SnapshotFilingFileManager
    ) throws -> (@MainActor () throws -> Void) {
        let words = "Synthetic filing check. Keep this thought beside the meeting notes."
        controller.text = words
        guard let source = controller.saveIfNeeded(), let sourceFile = source.fileURL,
              let targetFile = target.fileURL else {
            throw SnapshotError.fixtureValidationFailed
        }
        var dismissalRequests = 0
        // The hook normally stops capture. This static fixture has no capture
        // session, and must never resolve the real AppModel to close one.
        controller.onDismissRequested = { dismissalRequests += 1 }
        let existing = target.personalNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = existing.isEmpty ? words : "\(existing)\n\n\(words)"
        controller.fileIntoMeeting(target)
        let retainedSource = try Data(contentsOf: sourceFile)
        let filedTarget = try Data(contentsOf: targetFile)
        guard let decodedSource = MarkdownCodec.decode(String(decoding: retainedSource, as: UTF8.self)),
              let decodedTarget = MarkdownCodec.decode(String(decoding: filedTarget, as: UTF8.self)),
              decodedSource.id == source.id,
              decodedSource.summary.utf8.elementsEqual(words.utf8),
              decodedTarget.id == target.id,
              decodedTarget.personalNotes.utf8.elementsEqual(expected.utf8),
              decodedTarget.personalNotes.components(separatedBy: words).count == 2,
              let warning = controller.filingCompletionMessage else {
            throw SnapshotError.fixtureValidationFailed
        }
        let validate: @MainActor () throws -> Void = {
            // Retain the real controller, store and throwing file manager until
            // after the bitmap capture, so asynchronous work cannot turn this
            // partial success into an empty-pad fixture with no explanation.
            guard controller.text.isEmpty, !controller.canDiscard,
                  !controller.hasUnsavedFailure, !controller.hasUnsavedEdits,
                  controller.lastSavedAt == nil, controller.message == nil,
                  controller.recoveryWarning == nil,
                  controller.filingCompletionMessage == warning,
                  !warning.isEmpty, !controller.isWorking, !controller.isContinuous,
                  !controller.isPresenting, dismissalRequests == 1,
                  files.attemptedTrashURLs == [sourceFile],
                  store.note(matching: source.libraryIdentity) != nil,
                  store.note(matching: target.libraryIdentity)?.personalNotes
                    .utf8.elementsEqual(expected.utf8) == true,
                  try Data(contentsOf: sourceFile) == retainedSource,
                  try Data(contentsOf: targetFile) == filedTarget else {
                throw SnapshotError.fixtureValidationFailed
            }
        }
        try validate()
        return validate
    }

    @MainActor
    private static func validateAssistantFixture(
        mode: String, controller: QuickNoteController, gate: SnapshotAssistantGate?,
        originalText: String
    ) throws {
        guard let gate, !gate.wasReleased,
              controller.text.utf8.elementsEqual(originalText.utf8),
              !controller.isPresenting, !controller.isContinuous else {
            throw SnapshotError.fixtureValidationFailed
        }
        if mode.contains("unavailable") {
            guard controller.engine == .onDevice,
                  controller.availableEngines == [.codex],
                  !controller.hasConsented(to: .codex),
                  !controller.isSelectedAssistantAvailable,
                  controller.canChooseAssistant, !controller.canRunAction,
                  !controller.isWorking, controller.runningEngine == nil,
                  controller.runningAction == nil, !controller.isStoppingAssistant,
                  controller.outboundEngine == nil, gate.callCount == 0 else {
                throw SnapshotError.fixtureValidationFailed
            }
        } else {
            let isStopping = mode.contains("stopping")
            guard controller.availableEngines == [.onDevice, .codex],
                  controller.hasConsented(to: .codex),
                  controller.engine == (isStopping ? .onDevice : .codex),
                  controller.isWorking, controller.runningEngine == .codex,
                  controller.runningAction == .summarize,
                  controller.isStoppingAssistant == isStopping,
                  controller.outboundEngine == .codex, !controller.canRunAction,
                  gate.callCount == 1, gate.receivedEngine == .codex,
                  gate.receivedAction == .summarize,
                  gate.receivedText?.utf8.elementsEqual(originalText.utf8) == true else {
                throw SnapshotError.fixtureValidationFailed
            }
        }
    }

    @MainActor
    private static func completeSnapshotTask(_ task: Task<Void, Never>) throws {
        var completed = false
        let observer = Task { @MainActor in
            await task.value
            completed = true
        }
        defer { observer.cancel() }
        try waitForSnapshotCondition { completed }
    }

    @MainActor
    private static func waitForSnapshotCondition(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard condition() else { throw SnapshotError.fixtureValidationFailed }
    }

    @MainActor
    private static func prepareRecoveryJournal(_ journal: DraftJournal) throws {
        var completed = false
        Task { @MainActor in
            await journal.scan()
            completed = true
        }
        let deadline = Date().addingTimeInterval(5)
        while !completed, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard completed else { throw SnapshotError.fixtureValidationFailed }
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

@MainActor
private final class SnapshotApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Models a provider that has accepted a request and is still cleaning up
/// after cancellation. Only the static renderer can release it; no CLI,
/// model, permission request, or window presentation is involved.
@MainActor
private final class SnapshotAssistantGate {
    private var continuation: CheckedContinuation<String, Never>?
    private(set) var callCount = 0
    private(set) var didStart = false
    private(set) var wasReleased = false
    private(set) var receivedAction: NoteAction?
    private(set) var receivedEngine: NoteAssistantEngine?
    private(set) var receivedText: String?

    func run(action: NoteAction, text: String, engine: NoteAssistantEngine) async -> String {
        callCount += 1
        guard !didStart else { return Self.result }
        didStart = true
        receivedAction = action
        receivedEngine = engine
        receivedText = text
        if wasReleased { return Self.result }
        return await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        wasReleased = true
        let pending = continuation
        continuation = nil
        pending?.resume(returning: Self.result)
    }

    private static let result = "Synthetic assistant output must not replace the fixture's own words."
}

@MainActor
private struct LiveFollowSnapshotHost: View {
    @ObservedObject private var meeting: MeetingCoordinator
    @State private var transcript: LiveTranscriptState
    @State private var partialRevision = 0
    @State private var isPaused = false
    @State private var isVisible = true

    init(meeting: MeetingCoordinator, transcript: LiveTranscriptState) {
        self.meeting = meeting
        _transcript = State(initialValue: transcript)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Synthetic live transcript replay")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("Recording controls are disabled. No audio, model, network, or permission action is available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Append passage") { appendPassage() }
                        .accessibilityIdentifier("live-follow-append")
                    Button("Update partial") { updatePartial() }
                        .accessibilityIdentifier("live-follow-partial")
                    Button(isPaused ? "Resume preview" : "Pause preview") {
                        isPaused.toggle()
                        Self.publish(transcript, paused: isPaused, to: meeting)
                    }
                    .accessibilityIdentifier("live-follow-pause")
                    Button(isVisible ? "Hide transcript" : "Reopen transcript") {
                        // Reopening does not publish a new revision. The real
                        // view's onAppear must find the current words itself.
                        isVisible.toggle()
                    }
                    .accessibilityIdentifier("live-follow-visibility")
                    Button("Short content") { reset(count: 1) }
                        .accessibilityIdentifier("live-follow-short")
                    Button("Reset 60") { reset(count: 60) }
                        .accessibilityIdentifier("live-follow-reset")
                }
                Text("\(transcript.segments.count) numbered passages. Revision \(transcript.revision). Preview \(isPaused ? "paused" : "running").")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("live-follow-state")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            Divider()
            if isVisible {
                LiveMeetingView(recordingControlsEnabled: false)
                    .environmentObject(meeting)
            } else {
                ContentUnavailableView(
                    "Live transcript hidden",
                    systemImage: "text.bubble",
                    description: Text("The synthetic passages and revision are unchanged. Reopen the transcript to check its latest position.")
                )
            }
        }
    }

    private func appendPassage() {
        let number = transcript.segments.count + 1
        transcript.segments.append(Self.segment(number: number))
        transcript.meetingPartial = "Synthetic partial after passage \(number). More test words are arriving."
        updateTranscript()
    }

    private func updatePartial() {
        partialRevision += 1
        transcript.meetingPartial = "Synthetic partial update \(partialRevision). "
            + String(repeating: "These are evolving test words for scroll acceptance. ", count: partialRevision % 3 + 1)
        updateTranscript()
    }

    private func reset(count: Int) {
        let nextRevision = transcript.revision + 1
        transcript = Self.seededTranscript(count: count)
        transcript.revision = nextRevision
        partialRevision = 0
        Self.publish(transcript, paused: isPaused, to: meeting)
    }

    private func updateTranscript() {
        transcript.revision += 1
        transcript.wordCount = transcript.segments.reduce(0) {
            $0 + $1.text.split(whereSeparator: \.isWhitespace).count
        }
        Self.publish(transcript, paused: isPaused, to: meeting)
    }

    static func seededTranscript(count: Int) -> LiveTranscriptState {
        let segments = (1...count).map { segment(number: $0) }
        return LiveTranscriptState(
            segments: segments,
            meetingPartial: "Synthetic partial after passage \(count). More test words are arriving.",
            microphonePartial: "",
            latestSource: .system,
            revision: 1,
            wordCount: segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        )
    }

    private static func segment(number: Int) -> TranscriptSegment {
        let label = String(format: "%03d", number)
        return TranscriptSegment(
            startTime: TimeInterval((number - 1) * 8),
            duration: 7,
            text: "Synthetic passage \(label). The team is reviewing a local interface using invented words. This numbered passage makes the reading position visible while later passages arrive.",
            source: number.isMultiple(of: 2) ? .microphone : .system
        )
    }

    static func publish(_ transcript: LiveTranscriptState, paused: Bool, to meeting: MeetingCoordinator) {
        // Preview state only assigns display values. It starts no recording,
        // timer, detector, transcription, or model work. Keep the phase and
        // its start date stable across every synthetic update.
        meeting.setPreviewState(
            phase: .recording(
                title: "Synthetic live transcript acceptance",
                startedAt: Date(timeIntervalSince1970: 1_788_100_000)
            ),
            elapsed: TimeInterval(transcript.segments.count * 8),
            liveTranscript: transcript,
            audioLevel: 0,
            isPaused: paused
        )
    }
}

@MainActor
private struct CopyNoticeSnapshotHost: View {
    let longMessage: String
    @State private var notice: CopyNoticeState
    @State private var text = "Synthetic preparation. Keep my words and selection while a notice is shown."

    init(initialMessage: String, longMessage: String) {
        self.longMessage = longMessage
        var initialState = CopyNoticeState()
        initialState.show(initialMessage, severity: .failure)
        _notice = State(initialValue: initialState)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Synthetic meeting")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(notice.current == nil ? "No notice" : "Synthetic notice acceptance")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("notice-fixture-state")
            NookNotesEditor(text: $text, placeholder: "My notes")
                .frame(minHeight: 60)
                .background(.background, in: RoundedRectangle(cornerRadius: NookRadius.control))
            HStack(spacing: 12) {
                Button("Show short error") {
                    notice.show(RegenerationCopy.retainedMessage(for: .ungrounded), severity: .failure)
                }
                .accessibilityIdentifier("notice-fixture-short-error")
                Button("Show long error") {
                    notice.show(longMessage, severity: .failure)
                }
                .accessibilityIdentifier("notice-fixture-long-error")
            }
            Text("Synthetic text only. No file, clipboard, capture, or provider actions are available.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .nookNotice(notice.current) { notice.dismiss(id: $0) }
        .background { NookAmbientBackground() }
    }
}

private struct StorageSnapshotFixture {
    let root: URL
    let locations: [StorageInventoryLocation]
    let expectations: String

    static func make(in directory: URL, usesLongPaths: Bool) throws -> Self {
        let manager = FileManager.default
        let relativeRoot = usesLongPaths
            ? "Storage acceptance/International product research and accessibility programme/Working documents for the 2026 synthesis and review/Local synthetic storage with deliberately long descriptive folder names"
            : "Storage acceptance"
        let requestedRoot = directory.appendingPathComponent(relativeRoot, isDirectory: true)
        try manager.createDirectory(
            at: requestedRoot, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Resolve only this newly created, owned fixture. The scanner rejects
        // symlink components, including Foundation's usual /var alias.
        guard let resolved = realpath(requestedRoot.path, nil) else {
            throw SnapshotError.storageFixturePathUnavailable
        }
        defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        func write(_ relativePath: String, bytes: Int) throws {
            let url = root.appendingPathComponent(relativePath)
            try manager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // Deliberately synthetic bytes. Only metadata is inspected, so no
            // valid recording, recovery document, or model cache is required.
            try Data(repeating: 0x53, count: bytes).write(to: url, options: .withoutOverwriting)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        try write("Notes/Synthetic planning.md", bytes: 128)
        try write("Notes/Synthetic research.md", bytes: 256)
        for index in 1...7 {
            let prefix = index.isMultiple(of: 2) ? ".nook-recovery-" : ".nook-write-"
            try write("Notes/\(prefix)\(UUID().uuidString).tmp", bytes: 1_024)
        }
        try write("Notes/.recordings/pending.notes.txt", bytes: 128)
        try write("Notes/.recordings/pending.recovery.json", bytes: 256)
        try write("Draft recovery/unfinished.json", bytes: 256)
        try write("Draft recovery/interrupted.tmp", bytes: 512)
        try write("Search cache/chunks.json", bytes: 1_024)
        try write("App caches/derived.bin", bytes: 2_048)
        try write("App caches/Updates/synthetic-download.tmp", bytes: 4_096)
        try write("Logs/events.jsonl", bytes: 128)
        try write("Excluded link target/should-not-be-counted.bin", bytes: 8_192)
        let excludedTarget = root.appendingPathComponent("Excluded link target", isDirectory: true)
        try manager.createSymbolicLink(
            at: root.appendingPathComponent("App caches/Linked folder not followed"),
            withDestinationURL: excludedTarget
        )
        let developerLog = root.appendingPathComponent("Logs/developer.log")
        if usesLongPaths {
            try manager.createSymbolicLink(
                at: developerLog,
                withDestinationURL: excludedTarget.appendingPathComponent("should-not-be-counted.bin")
            )
        }
        return Self(
            root: root,
            locations: [
                StorageInventoryLocation(id: .notes, url: root.appendingPathComponent("Notes"), scope: .markdownFiles),
                StorageInventoryLocation(id: .interruptedSaves, url: root.appendingPathComponent("Notes"), scope: .interruptedSaveFiles),
                StorageInventoryLocation(id: .recordings, url: root.appendingPathComponent("Notes/.recordings"), scope: .directFiles),
                StorageInventoryLocation(id: .drafts, url: root.appendingPathComponent("Draft recovery"), scope: .directFiles),
                StorageInventoryLocation(id: .searchCache, url: root.appendingPathComponent("Search cache/chunks.json"), scope: .file),
                StorageInventoryLocation(id: .appCache, url: root.appendingPathComponent("App caches"), scope: .directoryTree),
                StorageInventoryLocation(id: .eventLog, url: root.appendingPathComponent("Logs/events.jsonl"), scope: .file),
                StorageInventoryLocation(id: .developerLog, url: developerLog, scope: .file)
            ],
            expectations: "Expected files and logical bytes: notes 2 / 384; temporary saves 7 / 7168; recording recovery 2 / 384; drafts 2 / 768; search cache 1 / 1024; app caches 2 / 6144, partial with a skipped link; event log 1 / 128; developer log \(usesLongPaths ? "0 / 0, partial with a skipped link" : "not present")."
        )
    }
}

@MainActor
private struct StorageSnapshotHost: View {
    let fixture: StorageSnapshotFixture
    // Match Settings ownership so closing and reopening cannot accumulate
    // controllers while an earlier scan is still leaving a filesystem call.
    @StateObject private var inventory = StorageInventoryController()
    @State private var isReviewPresented = false
    @State private var libraryReviewCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Synthetic storage acceptance")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Review the production storage sheet using temporary synthetic files. Recording, assistant providers, and app settings are not available here.")
                .foregroundStyle(.secondary)
            Button("Review Storage…") {
                inventory.prepareForPresentation()
                isReviewPresented = true
            }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("storage-fixture-review")
            Text(fixture.expectations)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if libraryReviewCount > 0 {
                Text("Library review requested for synthetic data (\(libraryReviewCount)). No Library window was opened.")
                    .accessibilityIdentifier("storage-fixture-library-confirmation")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .sheet(isPresented: $isReviewPresented) {
            StorageInventoryView(
                locations: fixture.locations,
                reviewLibrary: { libraryReviewCount += 1 },
                inventory: inventory
            )
        }
    }
}

private enum SnapshotError: LocalizedError {
    case renderFailed
    case encodingFailed
    case fixtureValidationFailed
    case storageFixturePathUnavailable

    var errorDescription: String? {
        switch self {
        case .renderFailed: "SwiftUI did not produce a snapshot image."
        case .encodingFailed: "The rendered image could not be encoded as PNG."
        case .fixtureValidationFailed: "The Markdown fixture did not round-trip correctly."
        case .storageFixturePathUnavailable: "The synthetic storage fixture path could not be resolved."
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

/// This fixture reaches the real filing transaction, but no URL can reach the
/// user's Trash. Failure is injected only after the target's verified write.
private final class SnapshotFilingFileManager: FileManager {
    let directory: URL
    private(set) var attemptedTrashURLs: [URL] = []

    init(directory: URL) {
        self.directory = directory
        super.init()
    }

    override func trashItem(
        at url: URL,
        resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?
    ) throws {
        guard url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/") else {
            throw SnapshotError.fixtureValidationFailed
        }
        attemptedTrashURLs.append(url)
        throw CocoaError(.fileWriteNoPermission)
    }
}

struct SnapshotCalendarProvider: CalendarEventProviding {
    func requestAccess() async -> Bool { true }
    func events(between start: Date, end: Date) -> [CalendarMeetingEvent] {
        [CalendarMeetingEvent(title: "Research synthesis", attendeeCount: 4, startDate: Date().addingTimeInterval(5 * 60))]
    }
}
