import Foundation
import UserNotifications

@MainActor
final class MeetingNotificationService: NSObject, UNUserNotificationCenterDelegate {
    private enum Action {
        static let record = "NOOK_RECORD_MEETING"
        static let later = "NOOK_MEETING_LATER"
        static let recordCalendar = "NOOK_RECORD_CALENDAR"
        static let prep = "NOOK_OPEN_PREP"
        static let category = "NOOK_MEETING_DETECTED"
        static let upcomingCategory = "NOOK_UPCOMING_MEETING"
        static let upcomingPrepCategory = "NOOK_UPCOMING_MEETING_PREP"
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
        let recordCalendar = UNNotificationAction(
            identifier: Action.recordCalendar,
            title: "Record",
            options: [.foreground]
        )
        let prep = UNNotificationAction(
            identifier: Action.prep,
            title: "Prep brief",
            options: [.foreground]
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
                actions: [recordCalendar],
                intentIdentifiers: [],
                options: [.customDismissAction]
            ),
            UNNotificationCategory(
                identifier: Action.upcomingPrepCategory,
                actions: [prep, recordCalendar],
                intentIdentifiers: [],
                options: [.customDismissAction]
            ),
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
    ///
    /// When the library holds earlier sittings of this series, the notification
    /// says so and gains a Prep brief action; assembling and showing the brief
    /// still waits for a tap.
    func present(upcoming: CalendarMeetingEvent, priorSittings: Int = 0) {
        Task {
            let granted = (try? await center.requestAuthorization(
                options: [.alert, .sound]
            )) ?? false
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = "Starting soon"
            content.subtitle = upcoming.title
            var bodyText: String
            if priorSittings > 0 {
                bodyText =
                    "\(priorSittings) earlier sitting\(priorSittings == 1 ? "" : "s") in your library."
            } else if upcoming.attendeeCount > 0 {
                bodyText = "\(upcoming.attendeeCount) invited."
            } else {
                bodyText = ""
            }
            content.body = (bodyText + " Record this meeting locally with Nook?")
                .trimmingCharacters(in: .whitespaces)
            content.interruptionLevel = .passive
            content.categoryIdentifier = priorSittings > 0
                ? Action.upcomingPrepCategory
                : Action.upcomingCategory

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
            case Action.prep:
                // The brief itself lives in the library; opening it is a
                // routing concern, not the notification service's.
                NotificationCenter.default.post(
                    name: .nookRequestPrepBrief,
                    object: nil
                )
            case Action.later, UNNotificationDismissActionIdentifier:
                meeting.dismissPrompt()
            default:
                meeting.onPresentationRequested?()
            }
        }
    }
}
