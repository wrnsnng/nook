import AppKit
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
    var onMeetingStarted: ((DetectedMeeting) -> Void)?
    var onMeetingEnded: (() -> Void)?

    @Published private(set) var currentDetection: DetectedMeeting?
    @Published var isEnabled = UserDefaults.standard.object(forKey: "automaticDetection") as? Bool ?? true {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "automaticDetection") }
    }

    private var scanTask: Task<Void, Never>?
    private var candidate: DetectedMeeting?
    private var consecutiveHits = 0
    private var consecutiveMisses = 0

    func start() {
        guard scanTask == nil else { return }
        scanTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if isEnabled {
                    let detection = await Task.detached(priority: .utility) {
                        Self.detectMeetingWindow()
                    }.value
                    accept(detection)
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

    private func accept(_ detection: DetectedMeeting?) {
        if let detection {
            consecutiveMisses = 0
            if candidate == detection {
                consecutiveHits += 1
            } else {
                candidate = detection
                consecutiveHits = 1
            }

            if currentDetection == nil, consecutiveHits >= 2 {
                currentDetection = detection
                onMeetingStarted?(detection)
            }
        } else {
            candidate = nil
            consecutiveHits = 0
            guard currentDetection != nil else { return }
            consecutiveMisses += 1
            if consecutiveMisses >= 5 {
                currentDetection = nil
                consecutiveMisses = 0
                onMeetingEnded?()
            }
        }
    }

    private nonisolated static func detectMeetingWindow() -> DetectedMeeting? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for window in windows {
            guard
                let owner = window[kCGWindowOwnerName as String] as? String,
                let title = window[kCGWindowName as String] as? String,
                !title.isEmpty,
                isMeeting(owner: owner, title: title)
            else {
                continue
            }
            return DetectedMeeting(appName: friendlyAppName(owner), windowTitle: title)
        }
        return nil
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
        consecutiveHits = 0
        consecutiveMisses = 0
        currentDetection = nil
    }
}
