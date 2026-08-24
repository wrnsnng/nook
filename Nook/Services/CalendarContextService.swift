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
    // A fresh `EKEventStore` per call re-primed its calendar list and
    // permission state every poll; one store held for the provider's
    // lifetime is what EventKit itself recommends.
    //
    // Reads do not happen one at a time, which an earlier comment here claimed
    // they did. The poll fetches on a detached task while detection enrichment
    // reads synchronously on the main actor, and those two genuinely overlap.
    // `EKEventStore` is not documented as thread-safe, so every call into it
    // goes through one serial queue.
    nonisolated(unsafe) private let store = EKEventStore()
    private let queue = DispatchQueue(
        label: "co.common-tools.nook.calendar-store"
    )

    func requestAccess() async -> Bool {
        // The completion-handler form, so the request itself queues alongside
        // the reads. The async form has to suspend outside the queue, which is
        // the gap being closed. The callback touches nothing but its own
        // continuation, so it is free to arrive off the queue later.
        await withCheckedContinuation { continuation in
            queue.async {
                self.store.requestFullAccessToEvents { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func events(between start: Date, end: Date) -> [CalendarMeetingEvent] {
        // Enrichment runs on the main actor and can now wait behind one poll's
        // query. That is a bounded read of the local store, and a moment of
        // waiting beats two threads inside one `EKEventStore`.
        queue.sync { fetchEvents(between: start, end: end) }
    }

    private func fetchEvents(
        between start: Date,
        end: Date
    ) -> [CalendarMeetingEvent] {
        let predicate = store.predicateForEvents(
            withStart: start,
            end: end,
            calendars: nil
        )
        return store.events(matching: predicate)
            // All-day events (holidays, "Out of office") are not meetings
            // and have no meaningful start time to enrich or prompt from.
            .filter { !$0.isAllDay }
            .map { event in
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

    /// The nearest event inside the pre-meeting horizon, if any.
    ///
    /// Published so passive surfaces (the library's prep card) can follow
    /// along without polling; it clears once the event starts or calendar
    /// context switches off. Firing the one-time prompt remains separate.
    @Published private(set) var currentUpcomingEvent: CalendarMeetingEvent?

    /// Fired when an event is about to start and has not been prompted yet.
    var onUpcomingEvent: ((CalendarMeetingEvent) -> Void)?

    private let provider: any CalendarEventProviding
    private var pollTask: Task<Void, Never>?
    private var eventStoreObserver: NSObjectProtocol?
    /// One prompt per event per day; dismissing must never nag again, and
    /// this survives a relaunch so restarting Nook inside the same prompt
    /// window does not ask again either.
    private var promptedEventKeys: Set<String> = []

    private enum Keys {
        static let enabled = "useCalendarContext"
        static let promptedEventKeysDay = "CalendarContextService.promptedEventKeysDay"
        static let promptedEventKeysValues = "CalendarContextService.promptedEventKeysValues"
    }

    init(provider: any CalendarEventProviding = EventKitCalendarProvider()) {
        self.provider = provider
        isEnabled = UserDefaults.standard.bool(forKey: Keys.enabled)
        promptedEventKeys = Self.loadPromptedEventKeys()
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
            Self.clearPersistedPromptedEventKeys()
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
        observeEventStoreChanges()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = await self.pollOnce()
                try? await Task.sleep(for: delay)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        currentUpcomingEvent = nil
        if let eventStoreObserver {
            NotificationCenter.default.removeObserver(eventStoreObserver)
            self.eventStoreObserver = nil
        }
    }

    /// Calendar edits (an event moved, added, or was removed) must not wait
    /// for the next scheduled poll to be reflected. EventKit posts this
    /// whenever anything in the store changes; there is no more specific
    /// signal to filter on.
    private func observeEventStoreChanges() {
        guard eventStoreObserver == nil else { return }
        eventStoreObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` guarantees this fires on the main thread, the
            // same trapped-vs-safe distinction as the dictation shortcut's
            // reactivation observer.
            MainActor.assumeIsolated {
                self?.pollNowIfPolling()
            }
        }
    }

    private func pollNowIfPolling() {
        guard pollTask != nil else { return }
        pollTask?.cancel()
        pollTask = nil
        startPolling()
    }

    /// Fetches upcoming events, updates the published state, and fires the
    /// one-time prompt when due. Returns how long to wait before polling
    /// again.
    @discardableResult
    private func pollOnce() async -> Duration {
        let fallbackDelay = Duration.seconds(Self.maximumPollInterval)
        guard isEnabled, !accessDenied, let onUpcomingEvent else {
            return fallbackDelay
        }

        let now = Date()
        let provider = self.provider
        // EventKit's fetch is synchronous I/O; running it off the main actor
        // keeps this periodic poll from ever stalling the UI. One broader
        // query also tells scheduling when the next event is, so an empty
        // prompt horizon does not make the next poll arrive too late to
        // catch an event crossing into it later.
        let lookaheadEnd = now.addingTimeInterval(Self.schedulingLookahead)
        let events = await Task.detached(priority: .utility) {
            provider.events(between: now, end: lookaheadEnd)
        }.value

        let horizonStart = now.addingTimeInterval(90)
        let horizonEnd = now.addingTimeInterval(10 * 60)
        let candidates = events.filter {
            $0.startDate >= horizonStart && $0.startDate <= horizonEnd
        }

        // The nearest event in the horizon is published regardless of whether
        // its one-time prompt has fired, so passive surfaces stay accurate.
        currentUpcomingEvent = candidates.min {
            $0.startDate < $1.startDate
        }
        if let event = Self.promptCandidate(
            now: now,
            among: candidates,
            alreadyPrompted: promptedEventKeys
        ) {
            promptedEventKeys.insert(event.key)
            Self.persist(promptedEventKeys)
            onUpcomingEvent(event)
        }

        let nextEventStart = events
            .map(\.startDate)
            .filter { $0 > now }
            .min()
        return Self.nextPollDelay(now: now, nextEventStart: nextEventStart)
    }

    static let minimumPollInterval: TimeInterval = 60
    static let maximumPollInterval: TimeInterval = 10 * 60
    /// How far ahead to look purely to schedule the next poll; independent
    /// of the much narrower prompt horizon itself.
    private static let schedulingLookahead: TimeInterval = 2 * 60 * 60

    /// Polls again just before the next known event would drop below the
    /// prompt horizon's lower bound, bounded so a quiet calendar still gets
    /// checked periodically and a busy one is never hammered.
    static func nextPollDelay(
        now: Date,
        nextEventStart: Date?
    ) -> Duration {
        guard let nextEventStart else {
            return .seconds(maximumPollInterval)
        }
        let interval = nextEventStart.timeIntervalSince(now) - 90
        return .seconds(
            min(maximumPollInterval, max(minimumPollInterval, interval))
        )
    }

    // MARK: - Persisting today's prompts

    static func dayKey(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: date
        )
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    /// Prompted keys are only meaningful for the day they were recorded: a
    /// key from yesterday refers to an event that has long since passed, and
    /// keeping it around would only ever risk colliding with a new event
    /// that happens to share the same start time and title.
    static func loadPromptedEventKeys() -> Set<String> {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Keys.promptedEventKeysDay)
            == dayKey(for: Date())
        else { return [] }
        return Set(
            defaults.stringArray(forKey: Keys.promptedEventKeysValues) ?? []
        )
    }

    static func persist(_ keys: Set<String>) {
        let defaults = UserDefaults.standard
        defaults.set(dayKey(for: Date()), forKey: Keys.promptedEventKeysDay)
        defaults.set(Array(keys), forKey: Keys.promptedEventKeysValues)
    }

    static func clearPersistedPromptedEventKeys() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Keys.promptedEventKeysDay)
        defaults.removeObject(forKey: Keys.promptedEventKeysValues)
    }
}
