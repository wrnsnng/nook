import Foundation
import UserNotifications

@MainActor
final class MeetingNotificationService: NSObject, UNUserNotificationCenterDelegate {
    private enum Action {
        static let record = "NOOK_RECORD_MEETING"
        static let later = "NOOK_MEETING_LATER"
        static let recordCalendar = "NOOK_RECORD_CALENDAR"
        static let category = "NOOK_MEETING_DETECTED"
        static let upcomingCategory = "NOOK_UPCOMING_MEETING"
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
            ),
            UNNotificationCategory(
                identifier: Action.upcomingCategory,
                actions: [
                    UNNotificationAction(
                        identifier: Action.recordCalendar,
                        title: "Record",
                        options: [.foreground]
                    )
                ],
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
            content.body = "Record this meeting locally with Nook?"
            content.interruptionLevel = .passive
            content.categoryIdentifier = Action.category

            let request = UNNotificationRequest(
                identifier: "nook-meeting-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }

    /// A quiet heads-up that a calendar event is about to start, even when no
    /// meeting-app signal has fired. Recording remains the user's choice.
    func present(upcoming: CalendarMeetingEvent) {
        Task {
            let granted = (try? await center.requestAuthorization(
                options: [.alert, .sound]
            )) ?? false
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = "Starting soon"
            content.subtitle = upcoming.title
            if upcoming.attendeeCount > 0 {
                content.body = """
                    \(upcoming.attendeeCount) invited. Record this meeting \
                    locally with Nook?
                    """
            } else {
                content.body = "Record this meeting locally with Nook?"
            }
            content.interruptionLevel = .passive
            content.categoryIdentifier = Action.upcomingCategory

            let request = UNNotificationRequest(
                identifier: "nook-upcoming-\(upcoming.key)",
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
        let eventTitle = String(
            response.notification.request.content.subtitle
        )
        await MainActor.run { [weak self, actionIdentifier, eventTitle] in
            guard let self, let meeting else { return }
            switch actionIdentifier {
            case Action.record:
                meeting.startDetectedMeeting()
            case Action.recordCalendar:
                meeting.startCalendarMeeting(title: eventTitle)
            case Action.later, UNNotificationDismissActionIdentifier:
                meeting.dismissPrompt()
            default:
                meeting.onPresentationRequested?()
            }
        }
    }
}
