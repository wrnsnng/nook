import Foundation
import UserNotifications

@MainActor
final class MeetingNotificationService: NSObject, UNUserNotificationCenterDelegate {
    private enum Action {
        static let record = "NOOK_RECORD_MEETING"
        static let later = "NOOK_MEETING_LATER"
        static let category = "NOOK_MEETING_DETECTED"
    }

    private weak var meeting: MeetingCoordinator?
    private let center = UNUserNotificationCenter.current()

    init(meeting: MeetingCoordinator) {
        self.meeting = meeting
        super.init()
        center.delegate = self

        let record = UNNotificationAction(
            identifier: Action.record,
            title: "Record",
            options: [.foreground]
        )
        let later = UNNotificationAction(
            identifier: Action.later,
            title: "Not now"
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Action.category,
                actions: [record, later],
                intentIdentifiers: [],
                options: [.customDismissAction]
            )
        ])
    }

    func present(_ detection: DetectedMeeting) {
        Task {
            let granted = (try? await center.requestAuthorization(
                options: [.alert, .sound]
            )) ?? false
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = "Meeting detected"
            content.subtitle = detection.appName
            content.body = "Record “\(detection.suggestedTitle)” locally with Nook?"
            content.interruptionLevel = .passive
            content.categoryIdentifier = Action.category

            let request = UNNotificationRequest(
                identifier: "nook-meeting-\(detection.appName)-\(detection.windowTitle)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let actionIdentifier = response.actionIdentifier
        await MainActor.run { [weak self, actionIdentifier] in
            guard let self, let meeting else { return }
            switch actionIdentifier {
            case Action.record:
                meeting.startDetectedMeeting()
            case Action.later, UNNotificationDismissActionIdentifier:
                meeting.dismissPrompt()
            default:
                meeting.onPresentationRequested?()
            }
        }
    }
}
