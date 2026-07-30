import AppKit
import CoreAudio
import CoreGraphics
import Foundation

struct DetectedMeeting: Equatable, Sendable {
    let appName: String
    let windowTitle: String

    var suggestedTitle: String {
        let generic = [
            "zoom meeting", "microsoft teams", "meeting", "google meet",
            "facetime", "webex", "around"
        ]
        let cleaned = windowTitle
            .replacingOccurrences(of: " - Google Chrome", with: "")
            .replacingOccurrences(of: " — Mozilla Firefox", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return generic.contains(cleaned.lowercased()) ? "\(appName) meeting" : cleaned
    }
}

@MainActor
final class MeetingDetector: ObservableObject {
    enum AudioActivity: Equatable, Sendable {
        case active
        case inactive
        case unavailable
    }

    private struct MeetingSignal: Equatable, Sendable {
        let detection: DetectedMeeting
        let audioActivity: AudioActivity
    }

    var onMeetingStarted: ((DetectedMeeting) -> Void)?
    var onMeetingEnded: (() -> Void)?

    @Published private(set) var currentDetection: DetectedMeeting?
    @Published var isEnabled = UserDefaults.standard.object(forKey: "automaticDetection") as? Bool ?? true {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "automaticDetection") }
    }

    private var scanTask: Task<Void, Never>?
    private var candidate: DetectedMeeting?
    private var candidateObservedActiveAudio = false
    private var suppressedInactiveAppName: String?
    private var consecutiveHits = 0
    private var consecutiveMisses = 0
    private var observedActiveAudio = false
    private var consecutiveInactiveAudioScans = 0

    func start() {
        guard scanTask == nil else { return }
        scanTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if isEnabled {
                    let signal = await Task.detached(priority: .utility) {
                        Self.detectMeetingSignal()
                    }.value
                    accept(signal)
                } else {
                    reset()
                }
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
    }

    private func accept(_ signal: MeetingSignal?) {
        if let signal {
            let detection = signal.detection
            consecutiveMisses = 0

            if suppressedInactiveAppName == detection.appName {
                guard signal.audioActivity == .active else { return }
                suppressedInactiveAppName = nil
            } else if suppressedInactiveAppName != nil {
                suppressedInactiveAppName = nil
            }

            if currentDetection != nil {
                acceptAudioActivity(signal.audioActivity)
                return
            }

            if candidate == detection {
                consecutiveHits += 1
                candidateObservedActiveAudio =
                    candidateObservedActiveAudio
                    || signal.audioActivity == .active
            } else {
                candidate = detection
                candidateObservedActiveAudio =
                    signal.audioActivity == .active
                consecutiveHits = 1
            }

            if currentDetection == nil, consecutiveHits >= 2 {
                currentDetection = detection
                observedActiveAudio = candidateObservedActiveAudio
                consecutiveInactiveAudioScans = 0
                onMeetingStarted?(detection)
            }
        } else {
            candidate = nil
            candidateObservedActiveAudio = false
            suppressedInactiveAppName = nil
            consecutiveHits = 0
            guard currentDetection != nil else { return }
            consecutiveMisses += 1
            if consecutiveMisses >= 5 {
                endCurrentDetection()
            }
        }
    }

    private func acceptAudioActivity(_ activity: AudioActivity) {
        switch activity {
        case .active:
            observedActiveAudio = true
            consecutiveInactiveAudioScans = 0
        case .inactive:
            guard observedActiveAudio else { return }
            consecutiveInactiveAudioScans += 1
            if consecutiveInactiveAudioScans >= 5 {
                endCurrentDetection(suppressWhileInactive: true)
            }
        case .unavailable:
            consecutiveInactiveAudioScans = 0
        }
    }

    private func endCurrentDetection(
        suppressWhileInactive: Bool = false
    ) {
        let endedAppName = currentDetection?.appName
        candidate = nil
        candidateObservedActiveAudio = false
        consecutiveHits = 0
        consecutiveMisses = 0
        observedActiveAudio = false
        consecutiveInactiveAudioScans = 0
        currentDetection = nil
        suppressedInactiveAppName =
            suppressWhileInactive ? endedAppName : nil
        onMeetingEnded?()
    }

    private nonisolated static func detectMeetingSignal() -> MeetingSignal? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        var fallbackSignal: MeetingSignal?
        for window in windows {
            guard
                let owner = window[kCGWindowOwnerName as String] as? String,
                let title = window[kCGWindowName as String] as? String,
                !title.isEmpty,
                isMeeting(owner: owner, title: title)
            else {
                continue
            }
            let signal = MeetingSignal(
                detection: DetectedMeeting(
                    appName: friendlyAppName(owner),
                    windowTitle: title
                ),
                audioActivity: audioActivity(for: owner)
            )
            if signal.audioActivity == .active {
                return signal
            }
            if fallbackSignal == nil {
                fallbackSignal = signal
            }
        }
        return fallbackSignal
    }

    private nonisolated static func audioActivity(
        for windowOwner: String
    ) -> AudioActivity {
        let tokens = audioIdentityTokens(for: windowOwner)
        guard !tokens.isEmpty, let processObjects = audioProcessObjects() else {
            return .unavailable
        }

        var foundMatchingProcess = false
        for processObject in processObjects {
            guard
                let processID = processIdentifier(for: processObject),
                let application = NSRunningApplication(
                    processIdentifier: processID
                )
            else {
                continue
            }

            let identity = [
                application.localizedName,
                application.bundleIdentifier
            ]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")
            guard tokens.contains(where: identity.contains) else { continue }

            foundMatchingProcess = true
            if audioProperty(
                kAudioProcessPropertyIsRunningInput,
                for: processObject
            ) == 1
                || audioProperty(
                    kAudioProcessPropertyIsRunningOutput,
                    for: processObject
                ) == 1
                || audioProperty(
                    kAudioProcessPropertyIsRunning,
                    for: processObject
                ) == 1
            {
                return .active
            }
        }

        return foundMatchingProcess ? .inactive : .unavailable
    }

    private nonisolated static func audioIdentityTokens(
        for windowOwner: String
    ) -> [String] {
        let owner = windowOwner.lowercased()
        if owner.contains("teams") { return ["teams", "msteams"] }
        if owner.contains("zoom") { return ["zoom"] }
        if owner.contains("chrome") { return ["chrome"] }
        if owner.contains("edge") { return ["edge"] }
        if owner.contains("safari") { return ["safari"] }
        if owner.contains("firefox") { return ["firefox"] }
        if owner.contains("facetime") { return ["facetime"] }
        if owner.contains("webex") { return ["webex"] }
        if owner.contains("slack") { return ["slack"] }
        if owner.contains("around") { return ["around"] }
        return []
    }

    private nonisolated static func audioProcessObjects() -> [AudioObjectID]? {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            systemObject,
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return nil
        }

        var objects = [AudioObjectID](
            repeating: kAudioObjectUnknown,
            count: Int(dataSize) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(
            systemObject,
            &address,
            0,
            nil,
            &dataSize,
            &objects
        ) == noErr else {
            return nil
        }
        return objects
    }

    private nonisolated static func processIdentifier(
        for processObject: AudioObjectID
    ) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processID: pid_t = 0
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(
            processObject,
            &address,
            0,
            nil,
            &dataSize,
            &processID
        ) == noErr else {
            return nil
        }
        return processID
    }

    private nonisolated static func audioProperty(
        _ selector: AudioObjectPropertySelector,
        for processObject: AudioObjectID
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            processObject,
            &address,
            0,
            nil,
            &dataSize,
            &value
        ) == noErr else {
            return nil
        }
        return value
    }

    private nonisolated static func isMeeting(owner: String, title: String) -> Bool {
        let value = "\(owner) \(title)".lowercased()
        let strongSignals = [
            "zoom meeting", "zoom webinar", "zoom waiting room",
            "microsoft teams meeting", "teams meeting",
            "meet.google.com", "google meet",
            "webex meeting", "cisco webex",
            "facetime call", "slack huddle", "around meeting",
            "whereby.com"
        ]
        if strongSignals.contains(where: value.contains) { return true }

        let callWords = [" meeting", " call", " huddle", " webinar"]
        let meetingApps = ["zoom", "teams", "facetime", "webex", "around", "whereby"]
        return meetingApps.contains(where: owner.lowercased().contains)
            && callWords.contains(where: title.lowercased().contains)
    }

    private nonisolated static func friendlyAppName(_ owner: String) -> String {
        if owner.localizedCaseInsensitiveContains("teams") { return "Teams" }
        if owner.localizedCaseInsensitiveContains("zoom") { return "Zoom" }
        if owner.localizedCaseInsensitiveContains("chrome") { return "Google Meet" }
        if owner.localizedCaseInsensitiveContains("safari") { return "Browser meeting" }
        if owner.localizedCaseInsensitiveContains("webex") { return "Webex" }
        return owner
    }

    private func reset() {
        candidate = nil
        candidateObservedActiveAudio = false
        suppressedInactiveAppName = nil
        consecutiveHits = 0
        consecutiveMisses = 0
        observedActiveAudio = false
        consecutiveInactiveAudioScans = 0
        currentDetection = nil
    }

    #if DEBUG
    func acceptForTesting(
        _ detection: DetectedMeeting?,
        audioActivity: AudioActivity = .unavailable
    ) {
        accept(
            detection.map {
                MeetingSignal(
                    detection: $0,
                    audioActivity: audioActivity
                )
            }
        )
    }
    #endif
}
