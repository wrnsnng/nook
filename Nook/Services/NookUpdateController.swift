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

/// Owns Sparkle for Nook's lifetime and exposes its user-controlled update
/// settings to SwiftUI. Sparkle handles download verification, installation,
/// relaunching, and its standard macOS update dialogs.
@MainActor
final class NookUpdateController: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false

    private let controller: SPUStandardUpdaterController

    init(startingUpdater: Bool = true) {
        controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

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
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        controller.updater.automaticallyDownloadsUpdates = enabled
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
