import Foundation

enum NookPermission: String, CaseIterable, Identifiable, Sendable {
    case microphone
    case speechRecognition
    case screenRecording

    var id: Self { self }

    var title: String {
        switch self {
        case .screenRecording:
            "Hear the whole meeting"
        case .microphone:
            "Include your voice"
        case .speechRecognition:
            "Turn audio into words"
        }
    }

    var setupDescription: String {
        switch self {
        case .screenRecording:
            "macOS asks twice here: first for Screen & System Audio Recording, then to let Nook access it directly without choosing a window for every meeting."
        case .microphone:
            "Microphone access lets Nook include what you say in the same local note."
        case .speechRecognition:
            "Speech Recognition turns the captured audio into text using Apple’s on-device model."
        }
    }

    var privacyExplanation: String {
        switch self {
        case .screenRecording:
            "The second macOS alert calls this bypassing the private window picker. Nook needs direct access after you approve a meeting; it captures only a tiny 2×2 frame and discards it."
        case .microphone:
            "Your microphone audio is processed on this Mac and removed after the note is saved unless you choose to keep audio."
        case .speechRecognition:
            "Transcription and summaries stay on this Mac. Nook has no account, server, or cloud upload."
        }
    }

    var symbol: String {
        switch self {
        case .screenRecording:
            "rectangle.inset.filled.and.person.filled"
        case .microphone:
            "mic.fill"
        case .speechRecognition:
            "captions.bubble.fill"
        }
    }

    var requestActionTitle: String {
        switch self {
        case .screenRecording:
            "Set up system audio"
        case .microphone:
            "Allow microphone"
        case .speechRecognition:
            "Allow speech recognition"
        }
    }

    var instruction: String {
        switch self {
        case .screenRecording:
            "Complete both macOS screen and system-audio prompts, then restart Nook if macOS asks."
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
