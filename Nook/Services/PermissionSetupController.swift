import AppKit
import AVFoundation
import CoreGraphics
import ScreenCaptureKit
import Speech

enum NookPermissionStatus: Equatable, Sendable {
    case notRequested
    case allowed
    case needsAttention

    var label: String {
        switch self {
        case .notRequested:
            "Not set up"
        case .allowed:
            "Allowed"
        case .needsAttention:
            "Open System Settings"
        }
    }

    var symbol: String {
        switch self {
        case .notRequested:
            "circle"
        case .allowed:
            "checkmark.circle.fill"
        case .needsAttention:
            "exclamationmark.circle.fill"
        }
    }
}

@MainActor
final class PermissionSetupController: ObservableObject {
    @Published private(set) var statuses: [NookPermission: NookPermissionStatus] = [:]
    @Published private(set) var permissionInFlight: NookPermission?

    private var attemptedScreenRecording = false
    private var didVerifyDirectCaptureAccess = false
    private var screenSetupFailed = false

    init() {
        refresh()
    }

    var allPermissionsAllowed: Bool {
        NookPermission.allCases.allSatisfy { status(for: $0) == .allowed }
    }

    func status(for permission: NookPermission) -> NookPermissionStatus {
        statuses[permission] ?? .notRequested
    }

    func refresh() {
        statuses[.screenRecording] = screenRecordingStatus
        statuses[.microphone] = Self.microphoneStatus
        statuses[.speechRecognition] = Self.speechRecognitionStatus
    }

    func refreshAfterBecomingActive() {
        if permissionInFlight != .screenRecording,
           CGPreflightScreenCaptureAccess(),
           !didVerifyDirectCaptureAccess {
            screenSetupFailed = false
        }
        refresh()
    }

    func request(_ permission: NookPermission) async {
        guard permissionInFlight == nil else { return }
        permissionInFlight = permission
        defer {
            permissionInFlight = nil
            refresh()
        }

        switch permission {
        case .screenRecording:
            attemptedScreenRecording = true
            screenSetupFailed = false

            if !CGPreflightScreenCaptureAccess() {
                guard CGRequestScreenCaptureAccess() else {
                    screenSetupFailed = true
                    return
                }
            }

            do {
                // Fetching shareable metadata triggers macOS's separate
                // direct-access consent without starting or saving a capture.
                _ = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: false
                )
                didVerifyDirectCaptureAccess = true
            } catch {
                screenSetupFailed = true
            }

        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined:
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            case .authorized, .denied, .restricted:
                break
            @unknown default:
                break
            }

        case .speechRecognition:
            guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else {
                return
            }
            _ = await SpeechAssets.requestAuthorizationStatus()
        }
    }

    func openSettings(for permission: NookPermission) {
        if permission == .screenRecording {
            // Let the user retry both layers after returning from Settings.
            attemptedScreenRecording = false
            screenSetupFailed = false
        }
        guard let url = permission.settingsURL else { return }
        NSWorkspace.shared.open(url)
        refresh()
    }

    private var screenRecordingStatus: NookPermissionStatus {
        Self.resolvedScreenRecordingStatus(
            screenCaptureAllowed: CGPreflightScreenCaptureAccess(),
            directCaptureVerified: didVerifyDirectCaptureAccess,
            attempted: attemptedScreenRecording,
            setupFailed: screenSetupFailed
        )
    }

    static func resolvedScreenRecordingStatus(
        screenCaptureAllowed: Bool,
        directCaptureVerified: Bool,
        attempted: Bool,
        setupFailed: Bool
    ) -> NookPermissionStatus {
        guard screenCaptureAllowed else {
            return attempted ? .needsAttention : .notRequested
        }
        if directCaptureVerified {
            return .allowed
        }
        return setupFailed ? .needsAttention : .notRequested
    }

    private static var microphoneStatus: NookPermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            .allowed
        case .notDetermined:
            .notRequested
        case .denied, .restricted:
            .needsAttention
        @unknown default:
            .needsAttention
        }
    }

    private static var speechRecognitionStatus: NookPermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            .allowed
        case .notDetermined:
            .notRequested
        case .denied, .restricted:
            .needsAttention
        @unknown default:
            .needsAttention
        }
    }
}
