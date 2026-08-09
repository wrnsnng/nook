import AppKit
import CoreAudio
import CoreGraphics
import Darwin
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

    enum Provider: String, CaseIterable, Sendable {
        case teams
        case zoom
        case googleMeet
        case webex
        case faceTime
        case slack
        case around
        case whereby

        var displayName: String {
            switch self {
            case .teams: "Teams"
            case .zoom: "Zoom"
            case .googleMeet: "Google Meet"
            case .webex: "Webex"
            case .faceTime: "FaceTime"
            case .slack: "Slack"
            case .around: "Around"
            case .whereby: "Whereby"
            }
        }
    }

    private struct MeetingWindowCandidate: Sendable {
        let provider: Provider
        let requiresActiveAudio: Bool
    }

    private struct MeetingSignal: Equatable, Sendable {
        let detection: DetectedMeeting
        let audioActivity: AudioActivity
    }

    var onMeetingStarted: ((DetectedMeeting) -> Void)?
    var onMeetingEnded: (() -> Void)?

    @Published private(set) var currentDetection: DetectedMeeting?
    @Published var isEnabled = MeetingDetector.initialDetectionPreference() {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "automaticDetection") }
    }

    private var scanTask: Task<Void, Never>?
    private var candidate: DetectedMeeting?
    private var suppressedInactiveAppName: String?
    private var consecutiveHits = 0
    private var consecutiveMisses = 0
    private var consecutiveInactiveAudioScans = 0

    /// New installs wait for an explicit choice in the welcome screen before
    /// inspecting window and audio-process metadata. Existing installs retain
    /// the behavior they had before this preference was introduced.
    private nonisolated static func initialDetectionPreference() -> Bool {
        let defaults = UserDefaults.standard
        if let configured = defaults.object(forKey: "automaticDetection") as? Bool {
            return configured
        }
        return defaults.bool(forKey: "hasSeenWelcome")
    }

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
            } else {
                candidate = detection
                consecutiveHits = 1
            }

            if currentDetection == nil, consecutiveHits >= 2 {
                currentDetection = detection
                consecutiveInactiveAudioScans = 0
                onMeetingStarted?(detection)
            }
        } else {
            candidate = nil
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
            consecutiveInactiveAudioScans = 0
        case .inactive:
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
        consecutiveHits = 0
        consecutiveMisses = 0
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
                let candidate = meetingWindowCandidate(
                    owner: owner,
                    title: title
                )
            else {
                continue
            }
            let activity = audioActivity(
                for: candidate.provider,
                windowOwner: owner
            )
            guard
                !candidate.requiresActiveAudio
                    || activity == .active
            else {
                continue
            }
            let signal = meetingSignal(
                provider: candidate.provider,
                title: title,
                audioActivity: activity
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
        for provider: Provider,
        windowOwner: String
    ) -> AudioActivity {
        let tokens = audioIdentityTokens(
            for: provider,
            windowOwner: windowOwner
        )
        guard !tokens.isEmpty, let processObjects = audioProcessObjects() else {
            return .unavailable
        }

        var foundMatchingProcess = false
        for processObject in processObjects {
            guard let processID = processIdentifier(
                for: processObject
            ) else {
                continue
            }

            let identity = processIdentity(processID)
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

    private nonisolated static func processIdentity(
        _ processID: pid_t
    ) -> String {
        var components: [String] = []
        var visited: Set<pid_t> = []
        var currentProcessID = processID

        // Safari and some native meeting apps put audio in a WebKit or helper
        // child process. Walking a short ancestry chain preserves the owning
        // app identity without treating every WebKit process as Safari.
        for _ in 0..<5 {
            guard
                currentProcessID > 0,
                visited.insert(currentProcessID).inserted
            else {
                break
            }

            if let application = NSRunningApplication(
                processIdentifier: currentProcessID
            ) {
                components.append(application.localizedName ?? "")
                components.append(application.bundleIdentifier ?? "")
            }
            if let processName = processName(currentProcessID) {
                components.append(processName)
            }
            guard let parent = parentProcessIdentifier(currentProcessID) else {
                break
            }
            currentProcessID = parent
        }

        return components
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    private nonisolated static func processName(
        _ processID: pid_t
    ) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(processID, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(
            decoding: buffer.prefix(Int(length)).map {
                UInt8(bitPattern: $0)
            },
            as: UTF8.self
        )
    }

    private nonisolated static func parentProcessIdentifier(
        _ processID: pid_t
    ) -> pid_t? {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let actualSize = proc_pidinfo(
            processID,
            PROC_PIDTBSDINFO,
            0,
            &info,
            expectedSize
        )
        guard actualSize == expectedSize, info.pbi_ppid > 0 else {
            return nil
        }
        return pid_t(info.pbi_ppid)
    }

    private nonisolated static func audioIdentityTokens(
        for provider: Provider,
        windowOwner: String
    ) -> [String] {
        switch provider {
        case .teams:
            return ["teams", "msteams"]
        case .zoom:
            return ["zoom", "cpthost", "cpt.host", "cptservice"]
        case .googleMeet:
            return browserAudioIdentityTokens(for: windowOwner)
                + ["google meet"]
        case .webex:
            let browserTokens = browserAudioIdentityTokens(
                for: windowOwner
            )
            return browserTokens.isEmpty
                ? ["webex", "ciscospark", "cisco"]
                : browserTokens
        case .faceTime:
            return ["facetime", "avconferenced"]
        case .slack:
            return ["slack", "tinyspeck"]
        case .around:
            return ["around"]
        case .whereby:
            return browserAudioIdentityTokens(for: windowOwner)
        }
    }

    private nonisolated static func browserAudioIdentityTokens(
        for windowOwner: String
    ) -> [String] {
        let owner = windowOwner.lowercased()
        if owner.contains("chrome") || owner.contains("google meet") {
            return ["chrome"]
        }
        if owner.contains("edge") { return ["edge"] }
        if owner.contains("safari") { return ["safari", "webkit"] }
        if owner.contains("firefox") { return ["firefox"] }
        if owner.contains("brave") { return ["brave"] }
        if owner == "arc" || owner.contains("arc browser") {
            return ["arc helper", "thebrowser.browser"]
        }
        if owner.contains("opera") { return ["opera"] }
        if owner.contains("vivaldi") { return ["vivaldi"] }
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

    private nonisolated static func meetingWindowCandidate(
        owner: String,
        title: String
    ) -> MeetingWindowCandidate? {
        let normalizedOwner = owner.lowercased()
        let normalizedTitle = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let value = "\(normalizedOwner) \(normalizedTitle)"

        if isGoogleMeetTitle(normalizedTitle)
            || value.contains("meet.google.com")
        {
            let genericLandingTitle =
                normalizedTitle == "google meet"
                || normalizedTitle == "meet"
            return MeetingWindowCandidate(
                provider: .googleMeet,
                requiresActiveAudio: genericLandingTitle
            )
        }
        if value.contains("whereby.com")
            || normalizedTitle.contains("whereby")
        {
            return MeetingWindowCandidate(
                provider: .whereby,
                requiresActiveAudio: false
            )
        }

        let provider: Provider?
        if normalizedOwner.contains("teams") {
            provider = .teams
        } else if normalizedOwner.contains("zoom") {
            provider = .zoom
        } else if normalizedOwner.contains("google meet") {
            provider = .googleMeet
        } else if normalizedOwner.contains("webex") {
            provider = .webex
        } else if normalizedOwner.contains("facetime") {
            provider = .faceTime
        } else if normalizedOwner.contains("slack") {
            provider = .slack
        } else if normalizedOwner.contains("around") {
            provider = .around
        } else if normalizedOwner.contains("whereby") {
            provider = .whereby
        } else {
            provider = nil
        }

        if value.contains("webex meeting")
            || value.contains("cisco webex")
        {
            return MeetingWindowCandidate(
                provider: .webex,
                requiresActiveAudio: false
            )
        }
        if normalizedTitle.contains("webex") {
            return MeetingWindowCandidate(
                provider: .webex,
                requiresActiveAudio: !hasStrongCallTitle(
                    normalizedTitle,
                    provider: .webex
                )
            )
        }

        guard let provider else { return nil }
        return MeetingWindowCandidate(
            provider: provider,
            requiresActiveAudio: !hasStrongCallTitle(
                normalizedTitle,
                provider: provider
            )
        )
    }

    private nonisolated static func hasStrongCallTitle(
        _ title: String,
        provider: Provider
    ) -> Bool {
        let callWords = [
            "meeting", "call", "huddle", "webinar", "waiting room",
            "lobby"
        ]
        if callWords.contains(where: title.contains) {
            return true
        }

        switch provider {
        case .googleMeet:
            return isGoogleMeetTitle(title)
        case .faceTime:
            return title.contains("facetime") && title != "facetime"
        case .whereby:
            return title.contains("whereby")
        default:
            return false
        }
    }

    private nonisolated static func isGoogleMeetTitle(
        _ normalizedTitle: String
    ) -> Bool {
        normalizedTitle == "google meet"
            || normalizedTitle.contains("google meet")
            || normalizedTitle.contains("meet.google.com")
            || normalizedTitle == "meet"
            || normalizedTitle.hasPrefix("meet - ")
            || normalizedTitle.hasPrefix("meet — ")
            || normalizedTitle.hasPrefix("meet – ")
            || normalizedTitle.contains(" | meet")
    }

    private nonisolated static func meetingSignal(
        provider: Provider,
        title: String,
        audioActivity: AudioActivity
    ) -> MeetingSignal {
        MeetingSignal(
            detection: DetectedMeeting(
                appName: provider.displayName,
                windowTitle: title
            ),
            audioActivity: audioActivity
        )
    }

    private func reset() {
        candidate = nil
        suppressedInactiveAppName = nil
        consecutiveHits = 0
        consecutiveMisses = 0
        consecutiveInactiveAudioScans = 0
        currentDetection = nil
    }

    #if DEBUG
    static func detectionForTesting(
        owner: String,
        title: String,
        audioActivity: AudioActivity
    ) -> DetectedMeeting? {
        guard let candidate = meetingWindowCandidate(
            owner: owner,
            title: title
        ) else {
            return nil
        }
        guard
            !candidate.requiresActiveAudio
                || audioActivity == .active
        else {
            return nil
        }
        return meetingSignal(
            provider: candidate.provider,
            title: title,
            audioActivity: audioActivity
        ).detection
    }

    static func audioIdentityMatchesForTesting(
        owner: String,
        title: String,
        processIdentity: String
    ) -> Bool {
        guard let candidate = meetingWindowCandidate(
            owner: owner,
            title: title
        ) else {
            return false
        }
        let identity = processIdentity.lowercased()
        return audioIdentityTokens(
            for: candidate.provider,
            windowOwner: owner
        ).contains(where: identity.contains)
    }

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
