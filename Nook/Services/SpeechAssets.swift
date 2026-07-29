import Foundation
import Speech

enum SpeechAssets {
    static func requestAuthorization() async throws {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard status == .authorized else {
            throw TranscriptionError.permissionDenied
        }
    }

    static func supportedLocale(for identifier: String) async throws -> Locale {
        let requested = Locale(identifier: identifier)
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            let name = requested.localizedString(forIdentifier: requested.identifier)
                ?? requested.identifier
            throw TranscriptionError.unsupportedLocale(name)
        }
        return supported
    }

    static func installIfNeeded(
        for modules: [any SpeechModule],
        locale: Locale
    ) async throws {
        let status = await AssetInventory.status(forModules: modules)
        switch status {
        case .installed:
            _ = try? await AssetInventory.reserve(locale: locale)
        case .supported:
            guard let request = try await AssetInventory.assetInstallationRequest(
                supporting: modules
            ) else {
                throw TranscriptionError.assetsUnavailable
            }
            try await request.downloadAndInstall()
            _ = try? await AssetInventory.reserve(locale: locale)
        case .downloading:
            for _ in 0..<60 {
                try await Task.sleep(for: .seconds(1))
                if await AssetInventory.status(forModules: modules) == .installed {
                    _ = try? await AssetInventory.reserve(locale: locale)
                    return
                }
            }
            throw TranscriptionError.assetsUnavailable
        case .unsupported:
            throw TranscriptionError.assetsUnavailable
        @unknown default:
            throw TranscriptionError.assetsUnavailable
        }
    }
}

