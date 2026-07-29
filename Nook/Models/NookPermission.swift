import Foundation

enum NookPermission: String, Sendable {
    case screenRecording
    case microphone
    case speechRecognition

    var instruction: String {
        switch self {
        case .screenRecording:
            "Allow Screen & System Audio Recording, then restart Nook."
        case .microphone:
            "Allow Microphone access, then try again."
        case .speechRecognition:
            "Allow Speech Recognition access, then try again."
        }
    }

    var primaryActionTitle: String {
        switch self {
        case .screenRecording:
            "Restart & Try Again"
        case .microphone, .speechRecognition:
            "Try Again"
        }
    }

    var settingsURL: URL? {
        let pane: String
        switch self {
        case .screenRecording:
            pane = "Privacy_ScreenCapture"
        case .microphone:
            pane = "Privacy_Microphone"
        case .speechRecognition:
            pane = "Privacy_SpeechRecognition"
        }
        return URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        )
    }
}
