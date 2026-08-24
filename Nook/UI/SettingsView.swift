import AppKit
import Security
import SwiftUI

/// The panes of Settings, named for what they hold.
///
/// `general` exists because appearance and calendar had been filed under
/// "Listening", where nobody looking for them would think to open: a pane
/// named for one job should not be where three unrelated ones live.
enum SettingsPane: Hashable {
    case general
    case listening
    case dictation
    case keyboard
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
    @EnvironmentObject private var shortcuts: ShortcutStore
    @State private var pendingStorageURL: URL?
    @State private var storageMessage: String?
    @State private var orphanPendingDeletion: OrphanedRecording?
    @State private var selectedPane: SettingsPane
    @State private var accessibilityGranted = TextInsertionService.isTrusted
    /// Nil until the bundle's signature has been read, which happens off the
    /// main thread the first time About is shown.
    @State private var signature: NookCodeSignature?

    init(initialPane: SettingsPane = .general) {
        _selectedPane = State(initialValue: initialPane)
    }

    var body: some View {
        TabView(selection: $selectedPane) {
            generalPane
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(SettingsPane.general)

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

            keyboardPane
                .tabItem {
                    Label("Keyboard", systemImage: "command")
                }
                .tag(SettingsPane.keyboard)

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

    /// Appearance and calendar: the two settings that are about Nook itself
    /// rather than about a thing Nook does.
    private var generalPane: some View {
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
        }
        .formStyle(.grouped)
    }

    private var listeningPane: some View {
        Form {
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
                    // A Mac whose region differs from its language reports an
                    // identifier like "en_US@rg=auzzzz", which matched none of
                    // the rows below. The picker then drew blank, so the one
                    // thing it did not show was the language Nook was actually
                    // going to transcribe in.
                    if Self.locales.allSatisfy({
                        $0.0 != meeting.localeIdentifier
                    }) {
                        Text(Self.name(forLocale: meeting.localeIdentifier))
                            .tag(meeting.localeIdentifier)
                    }

                    ForEach(Self.locales, id: \.0) { identifier, name in
                        Text(name).tag(identifier)
                    }
                }
            } header: {
                Label("Transcription", systemImage: "captions.bubble")
            } footer: {
                Text("Recognition runs with Apple’s on-device speech model. You can change the language between meetings.")
            }

            storageSection
        }
        .formStyle(.grouped)
    }

    /// Where what Nook hears ends up, and for how long. Filed with listening
    /// rather than with privacy because it is the end of the same sentence:
    /// hear the meeting, write it down, keep it here.
    private var storageSection: some View {
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
                    ShortcutRecorderView(
                        shortcut: dictation.shortcut,
                        onChange: { dictation.setShortcut($0) },
                        accessibilityLabel: "Dictation shortcut"
                    )
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
                Label("Voice typing", systemImage: "keyboard")
            } footer: {
                Text(
                    dictation.isEnabled
                        ? "\(dictation.activation.detail) Your words appear as you speak, then land in whichever text field has focus."
                        : "Hold a shortcut anywhere on your Mac, speak, and Nook types it into the field you are already in."
                )
            }

            // Switched off, this pane used to be a single toggle in an empty
            // window, which reads as a feature that failed to load rather than
            // one waiting to be turned on. These two rows say what the switch
            // is actually offering.
            if !dictation.isEnabled {
                Section {
                    PrivacyFeatureRow(
                        symbol: "text.cursor",
                        title: "Your words, in any field",
                        detail: "A message, a search box, a document. Speech is recognised on this Mac, and only settled words are typed."
                    )
                    PrivacyFeatureRow(
                        symbol: "note.text",
                        title: "Somewhere for a stray thought",
                        detail: "With no text field focused, the same shortcut opens a quick note instead of doing nothing."
                    )
                } header: {
                    Label("What this adds", systemImage: "wand.and.stars")
                } footer: {
                    Text("Dictation is off until you turn it on, and asks for Accessibility access only the first time you use it. Meeting notes work without it.")
                }
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
                            Button("Keep on this Mac") {
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
        }
    }

    private var isAppleIntelligenceAvailable: Bool {
        DictationRefiner.isModelAvailable
    }

    /// Every Nook shortcut in one pane, each recorded the same way dictation
    /// is: press the combination you want.
    private var keyboardPane: some View {
        Form {
            Section {
                ForEach(NookShortcutID.allCases) { id in
                    LabeledContent(id.title) {
                        HStack(spacing: NookSpacing.small) {
                            if shortcuts.isOverridden(id) {
                                Button {
                                    shortcuts.set(nil, for: id)
                                } label: {
                                    Image(systemName: "arrow.counterclockwise")
                                        .font(NookType.caption)
                                }
                                .buttonStyle(.borderless)
                                .help("Restore the default, "
                                    + id.defaultShortcut.spokenDescription + ".")
                                .accessibilityLabel(
                                    "Reset \(id.title) to default"
                                )
                            }
                            ShortcutRecorderView(
                                shortcut: shortcuts.binding(for: id),
                                onChange: { shortcuts.set($0, for: id) },
                                accessibilityLabel: "\(id.title) shortcut"
                            )
                        }
                    }
                }
            } header: {
                Label("Shortcuts", systemImage: "command")
            } footer: {
                Text(shortcutsFooter)
            }

            if !shortcuts.conflicts().isEmpty || hasDictationConflict {
                Section {
                    ForEach(shortcutConflictLines(), id: \.self) { line in
                        Label(line, systemImage: "exclamationmark.triangle")
                            .font(NookType.caption)
                            .foregroundStyle(NookPalette.warning)
                    }
                } header: {
                    Label("Shared combinations", systemImage: "square.on.square")
                } footer: {
                    Text(
                        "Two actions sharing a combination means only one of them can respond to it."
                    )
                }
            }
        }
    }

    /// The dictation shortcut participates in conflict detection too: it is
    /// registered globally like Flag This Moment, so sharing with anything
    /// here would swallow the other action.
    private var hasDictationConflict: Bool {
        NookShortcutID.allCases.contains {
            shortcuts.binding(for: $0) == dictation.shortcut
        }
    }

    private func shortcutConflictLines() -> [String] {
        var lines = shortcuts.conflicts().map { group in
            group.map(\.title).joined(separator: " and ")
                + " share "
                + shortcuts.binding(for: group[0]).spokenDescription
                + "."
        }
        if hasDictationConflict {
            let shared = NookShortcutID.allCases.first {
                shortcuts.binding(for: $0) == dictation.shortcut
            }
            if let shared {
                lines.append(
                    "Dictation and \(shared.title) share "
                        + dictation.shortcut.spokenDescription + "."
                )
            }
        }
        return lines
    }

    private var shortcutsFooter: String {
        let globals = NookShortcutID.allCases
            .filter(\.isGlobal)
            .map(\.title)
            .joined(separator: " and ")
        return """
        Click a combination, then press the new keys. Escape cancels. \
        \(globals) works while any application is frontmost; the rest \
        work inside Nook's windows.
        """
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
                                if orphan.isAudioOnly {
                                    Text("Audio only. This may be the kept audio of a note you deleted.")
                                        .font(NookType.micro)
                                        .foregroundStyle(.secondary)
                                }
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
                                orphanPendingDeletion = orphan
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
                    Text("These are recordings Nook has no note for, usually because processing was interrupted before the write-up finished. The audio was kept so nothing was lost. Save one as a note, or delete it once you are done with it: deleting moves it to the Trash, where you can still get it back.")
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
                // Naming the one exception here is the point of the section.
                // A privacy summary that lists only the reassuring facts is
                // the kind of thing a user is right to stop believing.
                PrivacyFeatureRow(
                    symbol: "terminal",
                    title: "One exception: note actions",
                    detail: "A note action can be handed to Claude Code or the Codex CLI installed on this Mac, which sends that note on. Off by default, agreed to once per provider, and never for anything you have not run an action on.",
                    actionTitle: "Open dictation settings",
                    action: { selectedPane = .dictation }
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
        // Scanned here rather than on another pane: this is the pane that
        // shows what the scan finds, and someone who opens Settings straight
        // to Privacy was previously told about no stray recordings at all.
        .onAppear { recovery.scan() }
        .alert(
            "Move this recording to the Trash?",
            isPresented: Binding(
                get: { orphanPendingDeletion != nil },
                set: { if !$0 { orphanPendingDeletion = nil } }
            )
        ) {
            Button("Move to Trash", role: .destructive) {
                if let orphan = orphanPendingDeletion {
                    recovery.delete(orphan)
                }
                orphanPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                orphanPendingDeletion = nil
            }
        } message: {
            Text("This recording is the only copy of that conversation. It moves to the Trash and can be restored from there, or you can save it as a note first.")
        }
    }

    private var aboutPane: some View {
        VStack(spacing: 16) {
            Spacer()

            NookMark(size: 88)
                .shadow(color: NookPalette.accent.opacity(0.2), radius: 22, y: 10)

            VStack(spacing: 6) {
                Text("Nook")
                    .font(NookType.title)
                Text("Meetings, tucked away.")
                    .font(NookType.body)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 7) {
                Text("Version \(appVersion)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                // Read from the running bundle rather than written here. A
                // hardcoded badge told every local and ad-hoc build it was
                // Developer ID signed, which is exactly the claim a user would
                // want to be able to trust.
                if let signature {
                    Label(signature.label, systemImage: signature.symbol)
                        .font(NookType.micro.weight(.semibold))
                        .foregroundStyle(signature.tint)
                        .accessibilityLabel(signature.label)
                } else {
                    // Holds the badge's place while the bundle is being
                    // checked, so nothing under it jumps when the answer
                    // lands. Deliberately silent: a line saying the signature
                    // is being verified reads as a warning about the very
                    // thing it is about to confirm.
                    Label("Checking", systemImage: "checkmark.seal")
                        .font(NookType.micro.weight(.semibold))
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            }
            .task {
                // Off the main thread, and only once per pane. Verifying a
                // signature hashes every byte of the bundle; doing it inside a
                // view body meant the first draw of About paid for that hash
                // before it could show anything, which on a cold Mac is a
                // visible stall. The badge is a fact about the build, not
                // about anything the user is doing, so it can arrive late.
                guard signature == nil else { return }
                signature = await Task.detached(priority: .userInitiated) {
                    NookCodeSignature.current
                }.value
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
                    symbol: "arrow.down.app",
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

    /// A readable name for a locale Nook does not list, with any keyword
    /// suffix trimmed first so "en_US@rg=auzzzz" still resolves to the row it
    /// obviously means.
    private static func name(forLocale identifier: String) -> String {
        let core = String(identifier.prefix { $0 != "@" })
        if let listed = locales.first(where: { $0.0 == core }) {
            return listed.1
        }
        return Locale.current.localizedString(forIdentifier: core) ?? core
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

/// What the running bundle's code signature actually says.
///
/// About used to state "Developer ID signed · Common Tools Co." as a constant,
/// so a build from source, an ad-hoc re-sign, and a tampered copy all showed
/// the same green seal. macOS already knows the answer, so this asks it. The
/// check is entirely local: it reads the bundle on disk and evaluates Apple's
/// own Developer ID requirement. Nothing is contacted.
enum NookCodeSignature: Equatable, Sendable {
    case developerID(team: String)
    case builtFromSource

    /// Resolved once. Verifying a signature hashes the whole bundle, which is
    /// not work a settings pane should repeat on every redraw, and not work it
    /// should do on the main thread even once: read straight from a view body
    /// this hashed every byte of the app before About drew its first frame,
    /// which on a cold Mac with nothing in the page cache is a visible stall.
    /// `NookCodeSignatureReader` is what About reads; this stays for anything
    /// that genuinely wants the answer synchronously.
    static let current = resolve()

    var label: String {
        switch self {
        case .developerID(let team) where !team.isEmpty:
            "Developer ID signed · \(team)"
        case .developerID:
            "Developer ID signed"
        case .builtFromSource:
            "Built from source"
        }
    }

    var symbol: String {
        switch self {
        case .developerID: "checkmark.seal.fill"
        case .builtFromSource: "hammer"
        }
    }

    /// A contributor build is a normal thing to be running, not a fault, so it
    /// stays quiet rather than borrowing the warning colour.
    var tint: Color {
        switch self {
        case .developerID: NookPalette.success
        case .builtFromSource: .secondary
        }
    }

    /// The organisation out of a Developer ID leaf certificate's common name,
    /// which reads "Developer ID Application: Some Company (TEAMID)". Split out
    /// so the parsing can be tested without a signed bundle to hand.
    static func team(fromCommonName commonName: String) -> String {
        var name = commonName
        if let colon = name.firstIndex(of: ":") {
            name = String(name[name.index(after: colon)...])
        }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.hasSuffix(")"), let paren = name.lastIndex(of: "(") {
            name = String(name[..<paren])
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    static func resolve() -> NookCodeSignature {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return .builtFromSource
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode
        else {
            return .builtFromSource
        }

        // Apple's own marker for a Developer ID leaf certificate. Matching on
        // the certificate rather than on a name means a renamed or re-signed
        // copy cannot inherit the badge.
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf"
            + "[field.1.2.840.113635.100.6.1.13] exists"
        guard
            SecRequirementCreateWithString(
                text as CFString,
                [],
                &requirement
            ) == errSecSuccess,
            let requirement,
            SecStaticCodeCheckValidity(
                staticCode,
                [],
                requirement
            ) == errSecSuccess
        else {
            return .builtFromSource
        }

        return .developerID(team: signingTeam(of: staticCode))
    }

    private static func signingTeam(of code: SecStaticCode) -> String {
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                code,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &information
            ) == errSecSuccess,
            let details = information as? [String: Any],
            let certificates = details[kSecCodeInfoCertificates as String]
                as? [SecCertificate],
            let leaf = certificates.first
        else {
            return ""
        }

        var commonName: CFString?
        guard SecCertificateCopyCommonName(leaf, &commonName) == errSecSuccess,
              let commonName
        else {
            return ""
        }
        return team(fromCommonName: commonName as String)
    }
}

private struct PrivacyFeatureRow: View {
    let symbol: String
    let title: String
    let detail: String
    /// Set when the fact this row states is also something the user can go and
    /// control. A claim about privacy that cannot be checked is just a claim.
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(NookType.bodyEmphasized)
                .foregroundStyle(NookPalette.accent)
                .symbolRenderingMode(.monochrome)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .controlSize(.small)
                        .padding(.top, 1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        // Combined while the row is only a statement; kept separate once it
        // carries a button, which VoiceOver has to be able to reach.
        .accessibilityElement(children: action == nil ? .combine : .contain)
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

/// Per-app dictation styles: an app can have its own habit.
private struct PerAppDictationStylesSection: View {
    @State private var overrides: [String] = DictationStyle.overriddenBundleIDs
    @State private var pickedStyle: DictationStyle = .cleanUp
    @State private var pickedApp = ""
    @State private var openApps: [OpenApp] = []

    var body: some View {
        Section {
            HStack {
                // The app is chosen from a list rather than taken from
                // whichever app is frontmost. Pressing a button in Settings
                // makes Nook itself frontmost, so the old control recorded an
                // override for Nook every single time.
                Picker("App", selection: $pickedApp) {
                    Text("Choose an app").tag("")
                    ForEach(openApps) { app in
                        appLabel(bundleID: app.id, name: app.name)
                            .tag(app.id)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("App to give its own dictation style")
                .frame(maxWidth: 200)

                Picker("Style", selection: $pickedStyle) {
                    ForEach(DictationStyle.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Style used for new per-app overrides")
                .frame(width: 130)

                Button("Add") {
                    DictationStyle.setOverride(
                        pickedStyle,
                        forBundleID: pickedApp
                    )
                    overrides = DictationStyle.overriddenBundleIDs
                    pickedApp = ""
                }
                .disabled(pickedApp.isEmpty)
                .help("Give this app its own dictation style")
            }

            ForEach(overrides, id: \.self) { bundleID in
                LabeledContent {
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
                    .accessibilityLabel(
                        "Remove the style for \(OpenApp.name(forBundleID: bundleID))"
                    )
                } label: {
                    appLabel(
                        bundleID: bundleID,
                        name: OpenApp.name(forBundleID: bundleID)
                    )
                }
            }
        } header: {
            Label("Per-app styles", systemImage: "square.stack.3d.up")
        } footer: {
            Text("An app listed here always gets its own style, wherever you are when you hold the shortcut.")
        }
        .onAppear { openApps = OpenApp.current() }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.didLaunchApplicationNotification
            )
        ) { _ in
            openApps = OpenApp.current()
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.didTerminateApplicationNotification
            )
        ) { _ in
            openApps = OpenApp.current()
            // A quit app keeps its override: the habit belongs to the app, not
            // to this session of it.
        }
    }

    private func appLabel(bundleID: String, name: String) -> some View {
        Label {
            Text(name)
        } icon: {
            if let icon = OpenApp.icon(forBundleID: bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "app.dashed")
            }
        }
    }
}

/// An app the user could dictate into, and the name to call it by.
private struct OpenApp: Identifiable, Hashable {
    /// The bundle identifier, which is what an override is stored under.
    let id: String
    let name: String

    /// Apps with a Dock icon, which are the ones with a text field to dictate
    /// into. Nook is left out: an override for Nook would only ever apply to
    /// the quick note pad, which has its own controls.
    static func current() -> [OpenApp] {
        let own = Bundle.main.bundleIdentifier
        var seen: Set<String> = []
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, id != own,
                      seen.insert(id).inserted
                else { return nil }
                return OpenApp(id: id, name: app.localizedName ?? id)
            }
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    /// Looked up when the row is drawn rather than stored alongside the
    /// override. An app can be renamed, moved, or removed between the day the
    /// style was set and today, and a name written into defaults would go on
    /// insisting on the old one.
    static func name(forBundleID bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleID
        ) else {
            return bundleID
        }
        let displayed = FileManager.default.displayName(atPath: url.path)
        guard displayed.hasSuffix(".app") else { return displayed }
        return String(displayed.dropLast(4))
    }

    static func icon(forBundleID bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleID
        ) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
