import EventKit
import Foundation

/// A calendar event that plausibly describes the meeting being detected or
/// about to start. Everything here comes from the Mac's own calendar store.
struct CalendarMeetingEvent: Hashable, Sendable {
    let title: String
    let attendeeCount: Int
    let startDate: Date

    var key: String { "\(startDate.timeIntervalSince1970)|\(title)" }
}

/// Reads upcoming meetings from the local calendar.
///
/// Implemented behind a protocol so detection enrichment and pre-prompts can
/// be tested without EventKit, and so a disabled or denied state is
/// indistinguishable from an empty calendar for every caller.
protocol CalendarEventProviding: Sendable {
    func requestAccess() async -> Bool
    func events(between start: Date, end: Date) -> [CalendarMeetingEvent]
}

struct EventKitCalendarProvider: CalendarEventProviding {
    func requestAccess() async -> Bool {
        let store = EKEventStore()
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    func events(between start: Date, end: Date) -> [CalendarMeetingEvent] {
        let store = EKEventStore()
        let predicate = store.predicateForEvents(
            withStart: start,
            end: end,
            calendars: nil
        )
        return store.events(matching: predicate).map { event in
            CalendarMeetingEvent(
                title: event.title ?? "",
                attendeeCount: event.attendees?.count ?? 0,
                startDate: event.startDate
            )
        }
    }
}

/// Optional meeting context from the local calendar.
///
/// Off by default and permission-free until switched on: Nook asks for
/// calendar access at the moment someone enables it in Settings, not before.
/// Two uses, both still prompt-never-auto:
/// - enriching a detected meeting with its real event title;
/// - a quiet prompt shortly before an event starts, even when no app signal
///   has fired yet.
@MainActor
final class CalendarContextService: ObservableObject {
    @Published private(set) var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                isEnabled,
                forKey: Keys.enabled
            )
        }
    }
    /// Set when macOS declines or the user refuses access while enabling.
    @Published private(set) var accessDenied = false

    /// Fired when an event is about to start and has not been prompted yet.
    var onUpcomingEvent: ((CalendarMeetingEvent) -> Void)?

    private let provider: any CalendarEventProviding
    private var pollTask: Task<Void, Never>?
    /// One prompt per event per session; dismissing must never nag again.
    private var promptedEventKeys: Set<String> = []

    private enum Keys {
        static let enabled = "useCalendarContext"
    }

    init(provider: any CalendarEventProviding = EventKitCalendarProvider()) {
        self.provider = provider
        isEnabled = UserDefaults.standard.bool(forKey: Keys.enabled)
    }

    func setEnabled(_ enabled: Bool) async {
        isEnabled = enabled
        if enabled {
            let granted = await provider.requestAccess()
            accessDenied = !granted
            if granted {
                startPolling()
            } else {
                // Without access there is nothing this feature can do; leave
                // the switch off rather than promising a silent no-op.
                isEnabled = false
            }
        } else {
            stopPolling()
            promptedEventKeys.removeAll()
        }
    }

    func restoreSessionIfNeeded() {
        guard isEnabled else { return }
        startPolling()
    }

    /// The best event matching a detection happening right now, used to give
    /// the note a real name.
    func event(enrichingDetectionAt date: Date) -> CalendarMeetingEvent? {
        guard isEnabled, !accessDenied else { return nil }
        let events = provider.events(
            between: date.addingTimeInterval(-5 * 60),
            end: date.addingTimeInterval(10 * 60)
        )
        return Self.nearestEvent(to: date, among: events)
    }

    /// Nearest by absolute distance, so an event that started two minutes ago
    /// still enriches a late detection.
    static func nearestEvent(
        to date: Date,
        among events: [CalendarMeetingEvent]
    ) -> CalendarMeetingEvent? {
        events.min {
            abs($0.startDate.distance(to: date))
                < abs($1.startDate.distance(to: date))
        }
    }

    /// Which event deserves the pre-meeting prompt right now.
    static func promptCandidate(
        now: Date,
        among events: [CalendarMeetingEvent],
        alreadyPrompted: Set<String>
    ) -> CalendarMeetingEvent? {
        // Early enough to matter, late enough to be relevant, once per event.
        let horizonStart = now.addingTimeInterval(90)
        let horizonEnd = now.addingTimeInterval(10 * 60)
        return events
            .filter { $0.startDate >= horizonStart && $0.startDate <= horizonEnd }
            .filter { !alreadyPrompted.contains($0.key) }
            .min { $0.startDate < $1.startDate }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollOnce() {
        guard isEnabled, !accessDenied, let onUpcomingEvent else { return }
        let candidates = provider.events(
            between: Date().addingTimeInterval(90),
            end: Date().addingTimeInterval(10 * 60)
        )
        guard let event = Self.promptCandidate(
            now: Date(),
            among: candidates,
            alreadyPrompted: promptedEventKeys
        ) else { return }
        promptedEventKeys.insert(event.key)
        onUpcomingEvent(event)
    }
}
