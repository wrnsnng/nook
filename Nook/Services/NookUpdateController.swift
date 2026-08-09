import Combine
import Sparkle
import SwiftUI

enum NookUpdateFeed {
    static let releaseRepository = "wrnsnng/nook-releases"
    static let stableFeedTag = "updates"
    static let appcastFileName = "appcast.xml"
    static let publicEdKey =
        "apOw6+icVsAh8Emfd1cwAkndoeAV71+anDE/w6rkZM8="

    static var releaseDownloadBase: String {
        "https://github.com/\(releaseRepository)/releases/download"
    }

    static var appcastURLString: String {
        "\(releaseDownloadBase)/\(stableFeedTag)/\(appcastFileName)"
    }

    static func releaseTag(for version: String) -> String {
        "v\(version)"
    }

    static func archiveURLString(for version: String) -> String {
        "\(releaseDownloadBase)/\(releaseTag(for: version))/Nook-\(version).zip"
    }
}

enum NookBuildIdentity {
    static let officialBundleIdentifier = "com.localfirst.nook"
    static let officialBuildInfoKey = "NookOfficialBuild"

    static var permitsOfficialUpdates: Bool {
        permitsOfficialUpdates(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            officialBuildValue: Bundle.main.object(
                forInfoDictionaryKey: officialBuildInfoKey
            )
        )
    }

    static func permitsOfficialUpdates(
        bundleIdentifier: String?,
        officialBuildValue: Any?
    ) -> Bool {
        guard bundleIdentifier == officialBundleIdentifier else {
            return false
        }

        if let value = officialBuildValue as? Bool {
            return value
        }

        guard let value = officialBuildValue as? String else {
            return false
        }
        return ["1", "true", "yes"].contains(value.lowercased())
    }
}

/// Owns Sparkle for Nook's lifetime and exposes its user-controlled update
/// settings to SwiftUI. Sparkle handles download verification, installation,
/// relaunching, and its standard macOS update dialogs.
@MainActor
final class NookUpdateController: ObservableObject {
    let isUpdaterEnabled: Bool
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var availableVersion: String?

    private let userDriverDelegate: NookUpdateUserDriverDelegate
    private let controller: SPUStandardUpdaterController

    init(startingUpdater: Bool = true) {
        let isUpdaterEnabled = NookBuildIdentity.permitsOfficialUpdates
        self.isUpdaterEnabled = isUpdaterEnabled
        let userDriverDelegate = NookUpdateUserDriverDelegate()
        self.userDriverDelegate = userDriverDelegate
        controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater && isUpdaterEnabled,
            updaterDelegate: nil,
            userDriverDelegate: userDriverDelegate
        )
        userDriverDelegate.onAvailableVersionChanged = { [weak self] version in
            self?.availableVersion = version
        }

        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$automaticallyChecksForUpdates)
        updater.publisher(for: \.automaticallyDownloadsUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$automaticallyDownloadsUpdates)
    }

    func checkForUpdates() {
        guard isUpdaterEnabled else { return }
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard isUpdaterEnabled else { return }
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        guard isUpdaterEnabled else { return }
        controller.updater.automaticallyDownloadsUpdates = enabled
    }
}

/// Scheduled updates should feel like part of Nook rather than a dialog that
/// materializes behind somebody else's meeting. Manual checks still use
/// Sparkle's complete signed update flow; background discoveries become a
/// quiet menu-bar affordance until the user is ready.
@MainActor
private final class NookUpdateUserDriverDelegate:
    NSObject,
    @preconcurrency SPUStandardUserDriverDelegate
{
    var onAvailableVersionChanged: ((String?) -> Void)?

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate, !state.userInitiated else { return }
        onAvailableVersionChanged?(update.displayVersionString)
    }

    func standardUserDriverDidReceiveUserAttention(
        forUpdate update: SUAppcastItem
    ) {
        onAvailableVersionChanged?(nil)
    }
}

struct CheckForUpdatesCommand: Commands {
    @ObservedObject var updater: NookUpdateController

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
        }
    }
}
