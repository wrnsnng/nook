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
    private let storageLocations: @MainActor (URL) -> [StorageInventoryLocation]
    private let reviewStorageInLibrary: @MainActor () -> Void
    @EnvironmentObject private var store: MarkdownStore
    @EnvironmentObject private var detector: MeetingDetector
    @EnvironmentObject private var meeting: MeetingCoordinator
    @EnvironmentObject private var appearance: NookAppearanceController
    @EnvironmentObject private var updater: NookUpdateController
    @EnvironmentObject private var dictation: DictationCoordinator
    @EnvironmentObject private var quickNote: QuickNoteController
    @EnvironmentObject private var calendar: CalendarContextService
    @EnvironmentObject private var shortcuts: ShortcutStore
    @EnvironmentObject private var audioInputCheck: AudioInputCheckService
    @State private var pendingStorageURL: URL?
    @State private var storageMessage: String?
    @State private var showingStorageInventory = false
    // Keep one worker across sheet presentations. Closing a sheet cannot
    // interrupt a stalled filesystem syscall; reopening must reuse its queue.
    @StateObject private var storageInventory = StorageInventoryController()
    @State private var selectedPane: SettingsPane
    @State private var accessibilityGranted = TextInsertionService.isTrusted
    @State private var showingRestoreAllDefaultsConfirmation = false
    /// Nil until the bundle's signature has been read, which happens off the
    /// main thread the first time About is shown.
    @State private var signature: NookCodeSignature?

    init(
        initialPane: SettingsPane = .general,
        storageLocations: @escaping @MainActor (URL) -> [StorageInventoryLocation],
        reviewStorageInLibrary: @escaping @MainActor () -> Void
    ) {
        _selectedPane = State(initialValue: initialPane)
        self.storageLocations = storageLocations
        self.reviewStorageInLibrary = reviewStorageInLibrary
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
        .sheet(isPresented: $showingStorageInventory) {
            StorageInventoryView(
                locations: storageLocations(store.storageURL),
                reviewLibrary: reviewStorageInLibrary,
                inventory: storageInventory
            )
        }
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

            audioInputCheckSection
            storageSection
        }
        .formStyle(.grouped)
        .onDisappear {
            AppModel.shared.stopAudioInputCheck()
        }
    }

    private var audioInputCheckSection: some View {
        Section {
            AudioInputCheckMeterRow(
                label: AudioInputCheckTrack.microphone.label,
                level: audioInputCheck.levels.microphone
            )
            AudioInputCheckMeterRow(
                label: AudioInputCheckTrack.meeting.label,
                level: audioInputCheck.levels.meeting
            )

            HStack {
                switch audioInputCheck.phase {
                case .starting:
                    ProgressView()
                        .controlSize(.small)
                    Text("Starting test")
                case .stopping:
                    ProgressView()
                        .controlSize(.small)
                    Text("Stopping test")
                default:
                    EmptyView()
                }

                Spacer(minLength: NookSpacing.small)

                if audioInputCheck.isStopAvailable {
                    Button("Stop Test") {
                        AppModel.shared.stopAudioInputCheck()
                    }
                    .disabled(audioInputCheck.phase == .stopping)
                } else {
                    Button("Start Test") {
                        AppModel.shared.startAudioInputCheck()
                    }
                    .disabled(audioInputCheck.phase == .starting)
                }
            }

            if let errorMessage = audioInputCheck.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(NookType.caption)
                    .foregroundStyle(NookPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                if let permission = audioInputCheck.requiredPermission,
                   let url = permission.settingsURL {
                    Button("Open Permission Settings…") {
                        NSWorkspace.shared.open(url)
                    }
                    .accessibilityLabel(permission == .microphone
                        ? "Open Microphone permission settings"
                        : "Open Screen and System Audio Recording permission settings")
                }
            }
        } header: {
            Label("Test meeting audio", systemImage: "waveform.and.mic")
        } footer: {
            Text("Nook listens only while this test is running. It does not record, save audio, create a note, transcribe speech, or send anything. Normal macOS recording indicators still appear. Stop a meeting or dictation before starting the test.")
        }
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

            Button("Review Storage on This Mac…") {
                storageInventory.prepareForPresentation()
                showingStorageInventory = true
            }

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
            voiceTypingSection
            if !dictation.isEnabled {
                dictationOffSection
            }

            if dictation.isEnabled {
                dictationWritingSection
                PerAppDictationStylesSection()
                dictationPermissionSection
            }

            // Note actions are optional assistance for a saved quick note, not
            // part of recognition. Keeping this section outside the enabled
            // branch lets someone choose an assistant without enabling typing.
            noteActionsSection
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

    private var voiceTypingSection: some View {
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
    }

    /// Switched off, this pane used to be a single toggle in an empty window,
    /// which reads as a feature that failed to load rather than one waiting to
    /// be turned on. These two rows say what the switch is actually offering.
    private var dictationOffSection: some View {
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

    private var dictationWritingSection: some View {
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
                    .background(
                        NookPalette.paper,
                        in: .rect(cornerRadius: NookRadius.control)
                    )
                    .accessibilityLabel("Custom dictation instruction")
            }

            if dictation.style.usesLanguageModel, !isAppleIntelligenceAvailable {
                Label(
                    "Apple Intelligence is unavailable, so Nook will type your words unchanged.",
                    systemImage: "info.circle"
                )
                .font(NookType.caption)
                .foregroundStyle(.secondary)
            }
        } header: {
            Label("How Nook writes it", systemImage: "wand.and.stars")
        } footer: {
            Text("Nook checks every rewrite against what you actually said. If the wording drifts too far, your own words are typed instead. A dictated question is never answered, only written down.")
        }
    }

    private var dictationPermissionSection: some View {
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

    private var noteActionsSection: some View {
        Section {
            if quickNote.availableEngines.isEmpty {
                Label(
                    "No assistant on this Mac. Turn on Apple Intelligence in System Settings, or install Claude Code or Codex.",
                    systemImage: "info.circle"
                )
                .font(NookType.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Assistant", selection: engineSelection) {
                    if !quickNote.isSelectedAssistantAvailable {
                        Text("Choose an assistant").tag(quickNote.engine)
                    }
                    ForEach(quickNote.availableEngines) { engine in
                        Text(
                            engine.provider.map {
                                "\(engine.title) (sends to \($0))"
                            } ?? engine.title
                        )
                        .tag(engine)
                    }
                }
                .disabled(!quickNote.canChooseAssistant)
                .help(quickNote.selectedAssistantDescription)
                .accessibilityLabel("Assistant for note actions")
                .accessibilityValue(quickNote.selectedAssistantDescription)

                Text(quickNote.selectedAssistantDescription)
                    .font(NookType.caption)
                    .foregroundStyle(
                        quickNote.engine.leavesTheMac
                            ? AnyShapeStyle(NookPalette.warning)
                            : AnyShapeStyle(.secondary)
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Selected assistant")
                    .accessibilityValue(quickNote.selectedAssistantDescription)
            }

            // Availability and the next selected engine can change while an
            // earlier external operation is still stopping. Its disclosure
            // belongs to that operation until cleanup returns.
            if let outboundEngine = quickNote.outboundEngine {
                HStack(alignment: .top, spacing: NookSpacing.small) {
                    Image(systemName: "arrow.up.forward.app.fill")
                        .foregroundStyle(NookPalette.warning)
                        .accessibilityHidden(true)
                    Text(quickNote.outboundMessage)
                        .font(NookType.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Warning. \(quickNote.outboundMessage)")
                    Spacer(minLength: 0)
                    Button(quickNote.isStoppingAssistant ? "Stopping…" : "Keep on this Mac") {
                        quickNote.revokeConsent(for: outboundEngine)
                        quickNote.selectEngine(.onDevice)
                    }
                    .disabled(quickNote.isStoppingAssistant)
                    .help("Return to the on-device assistant and request cancellation of any external action. Text already sent cannot be recalled.")
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .contain)
            }
        } header: {
            Label("Note actions", systemImage: "wand.and.sparkles")
        } footer: {
            Text(noteActionsFooter)
        }
    }

    private var noteActionsFooter: String {
        guard !quickNote.availableEngines.isEmpty else {
            return "Turn on Apple Intelligence in System Settings, or install Claude Code or Codex, to use note actions."
        }
        guard quickNote.isSelectedAssistantAvailable else {
            return "Choose an available assistant to use note actions. Editing and saving remain available. External assistants require your consent before any note is sent."
        }

        return "This is the default assistant for every new note. \(quickNote.engine.detail) You can also change this choice in the quick note window."
    }

    private var isAppleIntelligenceAvailable: Bool {
        DictationRefiner.isModelAvailable
    }

    /// Every Nook shortcut in one pane, grouped by the job it serves. The
    /// catalog owns the section membership and row copy, while this view owns
    /// only presentation and the one-way route to Dictation settings.
    private var keyboardPane: some View {
        Form {
            ForEach(NookShortcutSection.allCases) { section in
                Section {
                    ForEach(section.shortcutIDs) { id in
                        keyboardShortcutRow(for: id)
                    }
                } header: {
                    Label(section.title, systemImage: section.symbol)
                } footer: {
                    Text(section.footer)
                }
            }

            dictationShortcutReference

            Section {
                HStack(alignment: .top, spacing: NookSpacing.medium) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Restore keyboard shortcuts")
                            .font(NookType.bodyEmphasized)
                        Text(
                            "Return every Nook shortcut to its original binding."
                        )
                        .font(NookType.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: NookSpacing.small)

                    Button("Restore All Defaults", role: .destructive) {
                        guard shortcuts.hasOverrides else { return }
                        showingRestoreAllDefaultsConfirmation = true
                    }
                    .disabled(!shortcuts.hasOverrides)
                    .help(
                        shortcuts.hasOverrides
                            ? "Restore every keyboard shortcut to its default."
                            : "All keyboard shortcuts already use their defaults."
                    )
                    .accessibilityLabel("Restore all keyboard shortcut defaults")
                    .accessibilityValue(
                        shortcuts.hasOverrides
                            ? "\(shortcuts.overrides.count) custom shortcuts"
                            : "All shortcuts use their defaults"
                    )
                }
                .padding(.vertical, NookSpacing.xSmall)
            } header: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            } footer: {
                Text(
                    "This affects only Nook's shortcuts. It does not change your Mac's keyboard settings."
                )
            }

            if !shortcutConflictLines().isEmpty {
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
        .formStyle(.grouped)
        .confirmationDialog(
            "Restore all keyboard shortcut defaults?",
            isPresented: $showingRestoreAllDefaultsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Restore All Defaults", role: .destructive) {
                guard shortcuts.hasOverrides else { return }
                shortcuts.resetAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This removes every custom keyboard shortcut and restores Nook's defaults."
            )
        }
    }

    /// A row is deliberately not another recorder. Dictation owns its
    /// modifier-only validation and persistence in Dictation settings, so
    /// Keyboard settings only shows the current value and provides a route.
    private var dictationShortcutReference: some View {
        Section {
            HStack(alignment: .top, spacing: NookSpacing.medium) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dictation")
                        .font(NookType.bodyEmphasized)
                    Text("Voice typing uses this shortcut anywhere on your Mac.")
                        .font(NookType.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: NookSpacing.small)

                VStack(alignment: .trailing, spacing: NookSpacing.xSmall) {
                    Text(dictation.shortcut.displayString)
                        .font(NookType.control.monospaced())
                        .accessibilityLabel("Dictation shortcut")
                        .accessibilityValue(dictation.shortcut.displayString)

                    Button("Open Dictation Settings") {
                        selectedPane = .dictation
                    }
                    .buttonStyle(.borderless)
                    .help("Change the Dictation shortcut and voice typing settings.")
                }
            }
            .padding(.vertical, NookSpacing.xSmall)
        } header: {
            Label("Voice typing", systemImage: "mic.and.signal.meter")
        } footer: {
            Text(
                "Dictation can use a global shortcut, including modifiers held on their own. Change it in the Dictation pane."
            )
        }
    }

    private func keyboardShortcutRow(for id: NookShortcutID) -> some View {
        VStack(alignment: .leading, spacing: NookSpacing.small) {
            HStack(alignment: .top, spacing: NookSpacing.medium) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(id.title)
                        .font(NookType.bodyEmphasized)
                    Text(id.detail)
                        .font(NookType.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(alignment: .top, spacing: NookSpacing.small) {
                    Text(id.scopeLabel)
                        .font(NookType.metadata)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(id.title) scope")
                        .accessibilityValue(id.scopeDescription)

                    if shortcuts.isOverridden(id) {
                        Button {
                            shortcuts.set(nil, for: id)
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(NookType.caption)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.borderless)
                        .help(
                            "Restore \(id.title) to \(id.defaultShortcut.spokenDescription)."
                        )
                        .accessibilityLabel("Reset \(id.title) to default")
                        .accessibilityValue(
                            "Default \(id.defaultShortcut.displayString)"
                        )
                    }

                    ShortcutRecorderView(
                        shortcut: shortcuts.binding(for: id),
                        onChange: { shortcuts.set($0, for: id) },
                        allowsModifierOnly: false,
                        accessibilityLabel: "\(id.title) shortcut"
                    )
                }
            }

            if let conflict = shortcutConflictMessage(for: id) {
                Label(conflict, systemImage: "exclamationmark.triangle")
                    .font(NookType.micro)
                    .foregroundStyle(NookPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(conflict)
            }
        }
        .padding(.vertical, NookSpacing.xSmall)
    }

    /// The dictation shortcut participates in conflict detection too: it is
    /// registered globally like Flag This Moment, so sharing with anything
    /// here would swallow the other action.
    private var hasDictationConflict: Bool {
        let dictationKey = ShortcutBindingKey(dictation.shortcut)
        return NookShortcutID.allCases.contains {
            ShortcutBindingKey(shortcuts.binding(for: $0)) == dictationKey
        }
    }

    /// The local warning repeats the conflict next to every affected control;
    /// the full Shared combinations section below remains for VoiceOver users
    /// who need one complete summary of all collisions.
    private func shortcutConflictMessage(for id: NookShortcutID) -> String? {
        let binding = shortcuts.binding(for: id)
        var names: [String] = []

        for group in shortcuts.conflicts() where group.contains(id) {
            names.append(contentsOf: group.filter { $0 != id }.map(\.title))
        }
        if ShortcutBindingKey(binding) == ShortcutBindingKey(dictation.shortcut) {
            names.append("Dictation")
        }

        guard !names.isEmpty else { return nil }
        return "Conflict: \(id.title) shares \(binding.spokenDescription) with \(readableNames(names))."
    }

    private func shortcutConflictLines() -> [String] {
        var lines = shortcuts.conflicts().map { group in
            group.map(\.title).joined(separator: " and ")
                + " share "
                + shortcuts.binding(for: group[0]).spokenDescription
                + "."
        }
        if hasDictationConflict {
            let dictationKey = ShortcutBindingKey(dictation.shortcut)
            for shared in NookShortcutID.allCases where
                ShortcutBindingKey(shortcuts.binding(for: shared)) == dictationKey {
                lines.append(
                    "Dictation and \(shared.title) share "
                        + dictation.shortcut.spokenDescription + "."
                )
            }
        }
        return Array(Set(lines)).sorted()
    }

    private func readableNames(_ names: [String]) -> String {
        switch names.count {
        case 0:
            return "another action"
        case 1:
            return names[0]
        case 2:
            return "\(names[0]) and \(names[1])"
        default:
            return names.dropLast().joined(separator: ", ")
                + ", and \(names[names.count - 1])"
        }
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
                    actionTitle: "Open note action settings",
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

            Section {
                Button("Review Storage on This Mac…") {
                    storageInventory.prepareForPresentation()
                    showingStorageInventory = true
                }
            } footer: {
                Text("See notes, audio, draft recovery, caches, and logs without reading their contents or deleting files.")
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
    @State private var isExpanded = false

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $isExpanded) {
                HStack {
                    // The app is chosen from a list rather than taken from
                    // whichever app is frontmost. Pressing a button in Settings
                    // makes Nook itself frontmost, so the old control recorded
                    // an override for Nook every single time.
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

                if overrides.isEmpty {
                    Text("No app-specific styles yet.")
                        .font(NookType.caption)
                        .foregroundStyle(.secondary)
                } else {
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
                }
            } label: {
                HStack {
                    Label("Per-app styles", systemImage: "square.stack.3d.up")
                    Spacer(minLength: NookSpacing.small)
                    Text(overrideSummary)
                        .font(NookType.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("Per-app dictation styles")
            .accessibilityValue(overrideSummary)
            .accessibilityHint(
                isExpanded
                    ? "Collapse the app-specific style controls"
                    : "Expand to add or change a style for one app"
            )
        } header: {
            Label("App-specific behavior", systemImage: "square.stack.3d.up")
        } footer: {
            Text(perAppFooter)
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

    private var overrideSummary: String {
        switch overrides.count {
        case 0:
            return "No overrides"
        case 1:
            return "1 app override"
        default:
            return "\(overrides.count) app overrides"
        }
    }

    private var perAppFooter: String {
        if isExpanded {
            return "An app listed here always gets its own style, wherever you are when you hold the shortcut."
        }
        if overrides.isEmpty {
            return "No app-specific styles are set. Expand this row to give one app its own dictation style."
        }
        return "\(overrideSummary). Expand this row to review or change them."
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

private struct AudioInputCheckMeterRow: View {
    let label: String
    let level: Double

    var body: some View {
        HStack(spacing: NookSpacing.small) {
            Text(label)
                .frame(width: 72, alignment: .leading)

            ProgressView(value: level, total: 1)
                .tint(NookPalette.accent)
                .accessibilityLabel("\(label) audio level")
                .accessibilityValue("\(AudioInputCheckService.percentage(for: level))%")

            Text("\(AudioInputCheckService.percentage(for: level))%")
                .font(NookType.metadata.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
                .accessibilityHidden(true)
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
