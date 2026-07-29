import AppKit
import SwiftUI

enum SettingsPane: Hashable {
    case listening
    case privacy
    case about
}

struct SettingsView: View {
    @EnvironmentObject private var store: MarkdownStore
    @EnvironmentObject private var detector: MeetingDetector
    @EnvironmentObject private var meeting: MeetingCoordinator
    @EnvironmentObject private var appearance: NookAppearanceController
    @State private var pendingStorageURL: URL?
    @State private var storageMessage: String?
    @State private var selectedPane: SettingsPane

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

            privacyPane
                .tabItem {
                    Label("Privacy", systemImage: "lock.shield")
                }
                .tag(SettingsPane.privacy)

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
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var appVersion: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        return version ?? "1.0"
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
