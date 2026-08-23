import AppKit
import SwiftUI

enum SettingsPane: Hashable {
    case listening
    case dictation
    case privacy
    case updates
    case about
}

struct SettingsView: View {
    @EnvironmentObject private var store: MarkdownStore
    @EnvironmentObject private var detector: MeetingDetector
    @EnvironmentObject private var meeting: MeetingCoordinator
    @EnvironmentObject private var appearance: NookAppearanceController
    @EnvironmentObject private var updater: NookUpdateController
    @EnvironmentObject private var dictation: DictationCoordinator
    @EnvironmentObject private var quickNote: QuickNoteController
    @EnvironmentObject private var recovery: RecordingRecovery
    @EnvironmentObject private var calendar: CalendarContextService
    @State private var pendingStorageURL: URL?
    @State private var storageMessage: String?
    @State private var selectedPane: SettingsPane
    @State private var accessibilityGranted = TextInsertionService.isTrusted

    init(initialPane: SettingsPane = .listening) {
        _selectedPane = State(initialValue: initialPane)
    }

    var body: some View {
        TabView(selection: $selectedPane) {
            listeningPane
                .tabItem {
                    Label("Listening", systemImage: "waveform.and.mic")
                }
                .tag(SettingsPane.listening)

            dictationPane
                .tabItem {
                    Label("Dictation", systemImage: "mic.and.signal.meter")
                }
                .tag(SettingsPane.dictation)

            privacyPane
                .tabItem {
                    Label("Privacy", systemImage: "lock.shield")
                }
                .tag(SettingsPane.privacy)

            updatesPane
                .tabItem {
                    Label(
                        "Updates",
                        systemImage: "arrow.triangle.2.circlepath.circle"
                    )
                }
                .tag(SettingsPane.updates)

            aboutPane
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
                .tag(SettingsPane.about)
        }
        .padding(20)
        .confirmationDialog(
            "Change the notes folder?",
            isPresented: Binding(
                get: { pendingStorageURL != nil },
                set: { if !$0 { pendingStorageURL = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Copy \(store.markdownFileCount) Notes and Use Folder") {
                applyStorageChange(copyExistingMarkdown: true)
            }
            Button("Use Folder Without Copying") {
                applyStorageChange(copyExistingMarkdown: false)
            }
            Button("Cancel", role: .cancel) {
                pendingStorageURL = nil
            }
        } message: {
            Text("Nook can copy your existing Markdown files into the new folder. The originals will remain where they are.")
        }
    }

    private var listeningPane: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance.selection) {
                    ForEach(NookAppearancePreference.allCases) { option in
                        Label(option.label, systemImage: option.symbol)
                            .tag(option)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Label("Look & feel", systemImage: "circle.lefthalf.filled")
            } footer: {
                Text("Auto follows your Mac. Light and Dark keep Nook fixed in that appearance.")
            }

            calendarSection

            Section {
                Toggle(
                    "Detect meetings automatically",
                    isOn: $detector.isEnabled
                )
                Toggle(
                    "Show live captions in the top panel",
                    isOn: $meeting.showLiveCaptions
                )
            } header: {
                Label("Meeting awareness", systemImage: "sparkles")
            } footer: {
                Text("Nook quietly watches for meeting windows from Zoom, Teams, Google Meet, FaceTime, Webex, and other common apps. The top panel and a macOS notification always ask before recording.")
            }

            Section {
                Picker("Spoken language", selection: $meeting.localeIdentifier) {
                    ForEach(Self.locales, id: \.0) { identifier, name in
                        Text(name).tag(identifier)
                    }
                }
            } header: {
                Label("Transcription", systemImage: "captions.bubble")
            } footer: {
                Text("Recognition runs with Apple’s on-device speech model. You can change the language between meetings.")
            }
        }
        .formStyle(.grouped)
    }

    /// Optional calendar context. Access is requested only when this switch
    /// is turned on, never at launch.
    private var calendarSection: some View {
        Section {
            Toggle(
                "Use my calendar for meeting context",
                isOn: Binding(
                    get: { calendar.isEnabled },
                    set: { enabled in
                        Task { await calendar.setEnabled(enabled) }
                    }
                )
            )
            if calendar.accessDenied {
                Label(
                    "Calendar access was declined. Allow Nook in System Settings, Privacy & Security, Calendars.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(NookPalette.danger)
            }
        } header: {
            Label("Calendar", systemImage: "calendar")
        } footer: {
            Text(
                "Read on this Mac only, to name meetings after their event and to mention one shortly before it starts. Events come from every calendar account set up in System Settings, Internet Accounts, including iCloud, Google, and Exchange, so there is nothing to sign in to here. Nook still asks before recording."
            )
        }
    }

    private var dictationPane: some View {
        Form {
            Section {
                Toggle("Dictate into any text field", isOn: $dictation.isEnabled)

                if dictation.isEnabled {
                    LabeledContent("Shortcut") {
                        ShortcutRecorderView(shortcut: dictation.shortcut) {
                            dictation.setShortcut($0)
                        }
                    }

                    Picker("Behaviour", selection: $dictation.activation) {
                        ForEach(DictationActivation.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }

                    if let error = dictation.shortcutError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(NookType.caption)
                            .foregroundStyle(NookPalette.warning)
                    }
                }
            } header: {
                Label("Voice typing", systemImage: "keyboard.badge.waveform")
            } footer: {
                Text(
                    dictation.isEnabled
                        ? "\(dictation.activation.detail) Your words appear as you speak, then land in whichever text field has focus."
                        : "Hold a shortcut anywhere on your Mac, speak, and Nook types it into the field you are already in."
                )
            }

            if dictation.isEnabled {
                Section {
                    Picker("Style", selection: $dictation.style) {
                        ForEach(DictationStyle.allCases) { option in
                            Label(option.title, systemImage: option.symbol)
                                .tag(option)
                        }
                    }

                    Text(dictation.style.detail)
                        .font(NookType.caption)
                        .foregroundStyle(.secondary)

                    if dictation.style == .custom {
                        TextEditor(text: $dictation.customPrompt)
                            .font(NookType.caption)
                            .frame(minHeight: 68)
                            .scrollContentBackground(.hidden)
                            .padding(NookSpacing.small)
                            .background(NookPalette.paper, in: .rect(cornerRadius: NookRadius.control))
                            .accessibilityLabel("Custom dictation instruction")
                    }

                    if dictation.style.usesLanguageModel, !isAppleIntelligenceAvailable {
                        Label(
                            "Apple Intelligence is unavailable, so Nook will type your words unchanged.",
                            systemImage: "info.circle"                        )
                        .font(NookType.caption)
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Label("How Nook writes it", systemImage: "wand.and.stars")
                } footer: {
                    Text("Nook checks every rewrite against what you actually said. If the wording drifts too far, your own words are typed instead. A dictated question is never answered, only written down.")
                }

                PerAppDictationStylesSection()

                Section {
                    Picker("Note actions run", selection: engineSelection) {
                        ForEach(quickNote.availableEngines) { engine in
                            Text(
                                engine.provider.map {
                                    "\(engine.title) (sends to \($0))"
                                } ?? engine.title
                            )
                            .tag(engine)
                        }
                    }
                    .disabled(quickNote.availableEngines.count < 2)

                    if let provider = quickNote.engine.provider {
                        HStack(alignment: .top, spacing: NookSpacing.small) {
                            Image(systemName: "arrow.up.forward.app.fill")
                                .foregroundStyle(NookPalette.warning)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Notes are sent to \(provider)")
                                    .font(NookType.caption.weight(.semibold))
                                Text("Every note you run an action on leaves this Mac. Nothing else does, and nothing is sent until you use an action.")
                                    .font(NookType.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Button("Keep Local") {
                                quickNote.revokeConsent(for: quickNote.engine)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Label("Spoken notes", systemImage: "note.text")
                } footer: {
                    Text(
                        quickNote.availableEngines.count < 2
                            ? "Tidy up, summarise, and find actions run with Apple Intelligence on this Mac. Install and sign into Claude Code or the Codex CLI to use those instead, with the subscription you already have."
                            : "This is the default for every new note. You can still change it for a single note in the note window."
                    )
                }

                Section {
                    HStack(alignment: .top, spacing: NookSpacing.medium) {
                        Image(
                            systemName: accessibilityGranted
                                ? "checkmark.circle.fill"
                                : "exclamationmark.circle.fill"
                        )
                        .foregroundStyle(
                            accessibilityGranted
                                ? NookPalette.success
                                : NookPalette.warning
                        )
                        .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(
                                accessibilityGranted
                                    ? "Accessibility access allowed"
                                    : "Accessibility access required"
                            )
                            .font(NookType.caption.weight(.semibold))
                            Text("Typing into another app is something only macOS can permit. Nook uses it to place your dictated text and nothing else.")
                                .font(NookType.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)

                        if !accessibilityGranted {
                            Button("Allow…") {
                                dictation.requestAccessibilityPermission()
                                dictation.openAccessibilitySettings()
                            }
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    Label("Permission", systemImage: "hand.raised.fill")
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            // The grant happens in System Settings, so the only reliable moment
            // to re-check is when the user comes back to Nook.
            accessibilityGranted = TextInsertionService.isTrusted
            quickNote.refreshEngines()
        }
        .onAppear {
            quickNote.refreshEngines()
            recovery.scan()
        }
    }

    private var isAppleIntelligenceAvailable: Bool {
        DictationRefiner.isModelAvailable
    }

    /// Routed through `selectEngine` so choosing an off-device engine here asks
    /// for agreement exactly as it does in the note window. A picker that
    /// quietly wrote the preference would be the easiest place in the app to
    /// turn off the privacy promise by accident.
    private var engineSelection: Binding<NoteAssistantEngine> {
        Binding(
            get: { quickNote.engine },
            set: { quickNote.selectEngine($0) }
        )
    }

    private var privacyPane: some View {
        Form {
            Section {
                LabeledContent("Notes folder") {
                    HStack(spacing: 9) {
                        Text(store.storageURL.path(percentEncoded: false))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") {
                            pendingStorageURL = store.selectStorageDirectory()
                        }
                    }
                    .frame(maxWidth: 330, alignment: .trailing)
                }

                Toggle(
                    "Keep extracted meeting audio",
                    isOn: $meeting.keepAudio
                )

                AudioRetentionSettingsRow()

                if let storageMessage {
                    Label(storageMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(NookPalette.danger)
                }
            } header: {
                Label("Storage", systemImage: "externaldrive")
            } footer: {
                Text("Every note is an ordinary Markdown file. When audio retention is off, the temporary recording is removed as soon as the note is safely written.")
            }

            if !recovery.orphans.isEmpty {
                Section {
                    ForEach(recovery.orphans) { orphan in
                        HStack(spacing: NookSpacing.small) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(orphan.dateLabel)
                                    .font(NookType.caption.weight(.medium))
                                Text(orphan.sizeLabel)
                                    .font(NookType.micro)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Button("Save as Note") {
                                recovery.recover(
                                    orphan,
                                    localeIdentifier: meeting.localeIdentifier
                                )
                            }
                            .controlSize(.small)
                            .disabled(recovery.isWorking)
                            Button("Reveal") { recovery.reveal(orphan) }
                                .controlSize(.small)
                            Button("Delete", role: .destructive) {
                                recovery.delete(orphan)
                            }
                            .controlSize(.small)
                            .disabled(recovery.isWorking)
                        }
                        .padding(.vertical, 1)
                    }

                    if let message = recovery.message {
                        Text(message)
                            .font(NookType.caption)
                            .foregroundStyle(.secondary)
                    }
                    if recovery.isWorking {
                        HStack(spacing: NookSpacing.small) {
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                            Text("Working through that recording locally. This can take a while.")
                                .font(NookType.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Label(
                        "Recordings without a note (\(recovery.totalSizeLabel))",
                        systemImage: "waveform.badge.exclamationmark"
                    )
                } footer: {
                    Text("These are meetings Nook recorded but could not finish writing up, usually because processing was interrupted. The audio was kept so nothing was lost. Save one as a note, or delete it once you are done with it.")
                }
            }

            Section {
                PrivacyFeatureRow(
                    symbol: "icloud.slash",
                    title: "No cloud account",
                    detail: "There is no Nook server and no sync service."
                )
                PrivacyFeatureRow(
                    symbol: "rectangle.and.text.magnifyingglass",
                    title: "Minimal screen capture",
                    detail: "A tiny 2×2 video frame enables system audio; it is discarded after extraction."
                )
                PrivacyFeatureRow(
                    symbol: "key.horizontal.fill",
                    title: "System-controlled access",
                    detail: "macOS controls microphone, speech, and system audio permissions."
                )

                HStack {
                    Spacer()
                    Button("Review Nook Setup…") {
                        AppModel.shared.openIntroduction()
                    }
                    Button("Open Privacy & Security…") {
                        meeting.revealPermissions()
                    }
                }
            } header: {
                Label("How privacy works", systemImage: "hand.raised.fill")
            }
        }
        .formStyle(.grouped)
    }

    private var aboutPane: some View {
        VStack(spacing: 16) {
            Spacer()

            NookMark(size: 88)
                .shadow(color: NookPalette.accent.opacity(0.2), radius: 22, y: 10)

            VStack(spacing: 6) {
                Text("Nook")
                    .font(NookType.title)
                Text("A quiet place where conversations settle.")
                    .font(NookType.body)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 7) {
                Text("Version \(appVersion)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                Label(
                    "Developer ID signed · Common Tools Co.",
                    systemImage: "checkmark.seal.fill"
                )
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(NookPalette.success)
            }

            Spacer()

            VStack(spacing: 6) {
                Text("Made for the Mac. Your meetings remain yours.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Link(
                    "Common Tools Co.",
                    destination: URL(string: "https://www.common-tools.co/")!
                )
                .font(.caption.weight(.semibold))

                HStack(spacing: 6) {
                    Link(
                        "Source code",
                        destination: URL(string: "https://github.com/wrnsnng/nook")!
                    )
                    Text("·")
                    Link(
                        "Apache-2.0",
                        destination: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!
                    )
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var updatesPane: some View {
        Form {
            Section {
                LabeledContent("Installed version") {
                    Text("\(appVersion) (\(appBuild))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            updater.isUpdaterEnabled
                                ? "Look for a newer Nook"
                                : "Contributor build"
                        )
                        Text(
                            updater.isUpdaterEnabled
                                ? "Checks the signed Common Tools Co. update feed."
                                : "Official automatic updates are disabled for this build identity."
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Check Now") {
                        updater.checkForUpdates()
                    }
                    .disabled(
                        !updater.isUpdaterEnabled
                            || !updater.canCheckForUpdates
                    )
                }
            } header: {
                Label(
                    "Software update",
                    systemImage: "arrow.triangle.2.circlepath"
                )
            }

            Section {
                Toggle(
                    "Automatically check for updates",
                    isOn: Binding(
                        get: {
                            updater.automaticallyChecksForUpdates
                        },
                        set: {
                            updater.setAutomaticallyChecksForUpdates($0)
                        }
                    )
                )
                .disabled(!updater.isUpdaterEnabled)

                Toggle(
                    "Download updates automatically",
                    isOn: Binding(
                        get: {
                            updater.automaticallyDownloadsUpdates
                        },
                        set: {
                            updater.setAutomaticallyDownloadsUpdates($0)
                        }
                    )
                )
                .disabled(
                    !updater.isUpdaterEnabled
                        || !updater.automaticallyChecksForUpdates
                )
            } header: {
                Label("Automatic updates", systemImage: "clock.arrow.circlepath")
            } footer: {
                Text(
                    updater.isUpdaterEnabled
                        ? "Sparkle checks the secure feed periodically. Every download is verified with an EdDSA signature and Apple Developer ID before Nook offers to install it."
                        : "Builds from source use a separate bundle identity and never contact Nook’s production update feed."
                )
            }

            Section {
                PrivacyFeatureRow(
                    symbol: "checkmark.seal.fill",
                    title: "Verified before installation",
                    detail: "Nook rejects an update if its feed, archive signature, or Developer ID does not match."
                )
                PrivacyFeatureRow(
                    symbol: "arrow.clockwise.app",
                    title: "A standard Mac experience",
                    detail: "Updates install through Sparkle’s native dialog and reopen Nook when ready."
                )
            } header: {
                Label("Trust & control", systemImage: "lock.shield")
            }
        }
        .formStyle(.grouped)
    }

    private var appVersion: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        return version ?? "1.0"
    }

    private var appBuild: String {
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String
        return build ?? "1"
    }

    private func applyStorageChange(copyExistingMarkdown: Bool) {
        guard let url = pendingStorageURL else { return }
        do {
            try store.switchStorageDirectory(
                to: url,
                copyExistingMarkdown: copyExistingMarkdown
            )
            storageMessage = nil
        } catch {
            storageMessage = error.localizedDescription
        }
        pendingStorageURL = nil
    }

    private static let locales = [
        ("en_AU", "English (Australia)"),
        ("en_US", "English (United States)"),
        ("en_GB", "English (United Kingdom)"),
        ("de_DE", "Deutsch"),
        ("fr_FR", "Français"),
        ("es_ES", "Español"),
        ("it_IT", "Italiano"),
        ("nl_NL", "Nederlands"),
        ("pt_BR", "Português (Brasil)"),
        ("ja_JP", "日本語")
    ]
}

private struct PrivacyFeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(NookPalette.accent)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// Opt-in automatic cleanup of kept meeting audio, with the window shown.
private struct AudioRetentionSettingsRow: View {
    @State private var isEnabled = AudioRetention.isEnabled
    @State private var days = AudioRetention.days

    var body: some View {
        HStack {
            Toggle("Delete kept audio older than", isOn: $isEnabled)
                .onChange(of: isEnabled) { _, enabled in
                    UserDefaults.standard.set(
                        enabled,
                        forKey: AudioRetention.enabledKey
                    )
                }

            if isEnabled {
                Picker("", selection: $days) {
                    ForEach([30, 60, 90, 180], id: \.self) { value in
                        Text("\(value) days").tag(value)
                    }
                }
                .labelsHidden()
                // The visible label is the toggle beside it; this keeps the
                // picker from being announced as an unnamed pop-up.
                .accessibilityLabel("How long kept audio is retained")
                .frame(width: 110)
                .onChange(of: days) { _, value in
                    UserDefaults.standard.set(value, forKey: AudioRetention.daysKey)
                }
            }
        }
    }
}

/// Per-app dictation styles: the frontmost app can have its own habit.
private struct PerAppDictationStylesSection: View {
    @State private var overrides: [String] = DictationStyle.overriddenBundleIDs
    @State private var pickedStyle: DictationStyle = .cleanUp

    var body: some View {
        Section {
            HStack {
                Button("Add for Frontmost App") {
                    guard let app = NSWorkspace.shared.frontmostApplication,
                          let bundleID = app.bundleIdentifier
                    else { return }
                    DictationStyle.setOverride(pickedStyle, forBundleID: bundleID)
                    overrides = DictationStyle.overriddenBundleIDs
                }
                .disabled(NSWorkspace.shared.frontmostApplication == nil)

                Spacer()

                Picker("", selection: $pickedStyle) {
                    ForEach(DictationStyle.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Style used for new per-app overrides")
                .frame(width: 130)
            }

            ForEach(overrides, id: \.self) { bundleID in
                LabeledContent(bundleID) {
                    Text(
                        DictationStyle.override(forBundleID: bundleID)?.title
                            ?? ""
                    )
                    .foregroundStyle(.secondary)
                    Button("Remove") {
                        DictationStyle.setOverride(nil, forBundleID: bundleID)
                        overrides = DictationStyle.overriddenBundleIDs
                    }
                    .controlSize(.small)
                }
            }
        } header: {
            Label("Per-app styles", systemImage: "square.stack.3d.up")
        } footer: {
            Text("An app listed here always gets its own style, wherever you are when you hold the shortcut. Switch to that app first, then press Add.")
        }
    }
}
