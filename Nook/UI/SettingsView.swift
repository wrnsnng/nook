import AppKit
import SwiftUI

enum SettingsPane: Hashable {
    case listening
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
