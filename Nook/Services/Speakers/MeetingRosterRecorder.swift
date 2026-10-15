import Foundation

/// Whether Nook reads participant names from the Zoom desktop app while it
/// records. Off until the user turns it on in Settings, Listening: it reads
/// another application's window, which Nook otherwise never does, and
/// switching it on is when Accessibility access is requested.
enum ZoomSpeakerNamesPreference {
    static let key = "nameSpeakersFromZoom"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? false
    }
}

/// Keeps what the meeting app showed about its participants during one
/// recording, on the recording's own timeline.
///
/// Readings are taken about once a second and placed at the recording offset
/// sampled just before the read, so they line up with transcript passages.
/// Nothing is read while the recording is paused: that audio is not in the
/// transcript, and a reading there would sit at the wrong place on resume.
///
/// The roster lives in memory until the note is written. Only names reach the
/// note, and only through the transcript's speaker labels and the participant
/// list; the second-by-second readings are dropped with the recording.
@MainActor
final class MeetingRosterRecorder {
    private(set) var roster = MeetingRoster()
    private var task: Task<Void, Never>?
    private let read: @Sendable () -> ZoomMeetingReading?
    private let isEnabled: () -> Bool
    private let isPermitted: () -> Bool
    private let interval: Duration
    /// Whether this recording read Zoom at all. Kept for the event log.
    private(set) var isActive = false
    /// Names whose tile agreed with the user's own mute button at every
    /// reading so far. Nil until the toolbar has been seen.
    private var selfCandidates: Set<String>?

    init(
        read: @escaping @Sendable () -> ZoomMeetingReading? = { ZoomAccessibilityReader.readMeeting() },
        // Names only ever go to separated voices, so without separation
        // there is nothing to read Zoom for.
        isEnabled: @escaping () -> Bool = {
            ZoomSpeakerNamesPreference.isEnabled() && SpeakerSeparationPreference.isEnabled()
        },
        isPermitted: @escaping () -> Bool = { TextInsertionService.isTrusted },
        interval: Duration = .seconds(1)
    ) {
        self.read = read
        self.isEnabled = isEnabled
        self.isPermitted = isPermitted
        self.interval = interval
    }

    /// Starts a fresh roster. `position` is the recording offset now, or nil
    /// while paused.
    func start(position: @escaping @MainActor () -> TimeInterval?) {
        task?.cancel()
        roster = MeetingRoster()
        isActive = false
        selfCandidates = nil
        guard isEnabled() else { return }
        guard isPermitted() else {
            NookEventLog.write(.speakersZoomNotPermitted)
            return
        }
        isActive = true
        let read = self.read
        let interval = self.interval
        task = Task { [weak self] in
            while !Task.isCancelled {
                if let time = position() {
                    // Off the main actor: an unresponsive app can hold an
                    // Accessibility call until its timeout.
                    let reading = await Task.detached(priority: .utility) { read() }.value
                    guard !Task.isCancelled, let self else { return }
                    if let reading { self.record(reading, at: time) }
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Stops reading and hands back everything seen.
    func stop() -> MeetingRoster {
        task?.cancel()
        task = nil
        resolveSelfFromMuteState()
        if isActive {
            NookEventLog.write(roster.participants.isEmpty && roster.selfName == nil
                ? .speakersZoomNothingRead : .speakersZoomRead)
            if !roster.activeSpeakers.isEmpty {
                NookEventLog.write(.speakersZoomActiveSpeakerSeen)
            }
        }
        isActive = false
        return roster
    }

    /// Forgets the recording's roster, for a discarded meeting.
    func discard() {
        task?.cancel()
        task = nil
        roster = MeetingRoster()
        selfCandidates = nil
    }

    /// Zoom only marks the user "(me)" while its participants panel is open.
    /// Otherwise the user is the one participant whose mute state matched
    /// their own mute button every time it was read. Two or more left means
    /// nobody's state ever told them apart, and nothing is assumed.
    private func resolveSelfFromMuteState() {
        guard roster.selfName == nil, let candidates = selfCandidates,
              candidates.count == 1, let name = candidates.first else { return }
        roster.selfName = name
        roster.participants.removeAll { $0 == name }
    }

    func record(_ reading: ZoomMeetingReading, at time: TimeInterval) {
        if let candidates = reading.selfCandidates, !candidates.isEmpty {
            selfCandidates = selfCandidates.map { $0.intersection(candidates) } ?? candidates
        }
        if let selfName = reading.selfName {
            roster.selfName = selfName
            roster.participants.removeAll { $0 == selfName }
        }
        for name in reading.participants
        where name != roster.selfName && !roster.participants.contains(name) {
            roster.participants.append(name)
        }
        if let speaker = reading.activeSpeaker, speaker != roster.selfName {
            roster.activeSpeakers.append(ActiveSpeakerObservation(time: time, name: speaker))
        }
    }
}
