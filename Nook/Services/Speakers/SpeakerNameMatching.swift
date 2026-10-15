import Foundation

/// One reading of who the meeting app showed as talking, on the note's
/// transcript timeline.
struct ActiveSpeakerObservation: Equatable, Sendable {
    let time: TimeInterval
    let name: String
}

/// What the meeting app showed about its participants over a recording.
struct MeetingRoster: Equatable, Sendable {
    /// Everyone the app listed at any point, in order first seen. Never the
    /// user themselves.
    var participants: [String] = []
    /// Who the app highlighted as talking, in time order.
    var activeSpeakers: [ActiveSpeakerObservation] = []
    /// The user's own display name in the app, when it marked one as theirs.
    var selfName: String?

    var isEmpty: Bool { participants.isEmpty && activeSpeakers.isEmpty }
}

/// Puts names to separated voices from the meeting app's active-speaker
/// highlight. Deterministic and pure, like `SpeakerAttribution`: it only
/// compares two timelines, so it cannot invent a name the app never showed.
///
/// The highlight and the voice separation are independent and both imperfect.
/// The app's highlight lags speech by a moment and sticks to the last talker
/// through silence. So a voice is named only when one name clearly dominates
/// the time it spoke. Everything else stays "Unclear · voice N" for the user
/// to name, which is a better outcome than a confident wrong name.
///
/// Several voices can clearly belong to one name: people sharing a meeting
/// room behind one Zoom tile. Each then keeps the name with its own number,
/// "Boardroom · voice 1", so the room's people stay apart in the transcript.
/// Separation occasionally splits one person in two, which reads the same
/// way; that is honest about what is known, where giving the name to only the
/// stronger voice would leave the other looking like a stranger.
enum SpeakerNameMatching {
    /// A reading is taken to hold until the next one, but never longer than
    /// this. Readings come about once a second, so this bridges one missed
    /// read. A longer gap means the app could not be read (window hidden,
    /// panel changed), and stretching the last name across it would be a
    /// guess.
    static let maximumHold: TimeInterval = 2
    /// Zoom marks a speaker about a second after they start talking: in a
    /// live trace on Zoom 7.1 the marker followed an unmute by 1.2 seconds.
    /// Each reading is therefore taken to begin this much earlier. Together
    /// with `maximumHold` it stays below `minimumEvidence`, so one stray
    /// reading names nobody.
    static let highlightLag: TimeInterval = 0.75
    /// Overlap below this is coincidence, not evidence.
    static let minimumEvidence: TimeInterval = 3
    /// The winning name's share of all highlighted time across the voice.
    static let minimumShare = 0.6
    /// How far the winner must lead the runner-up.
    static let minimumLead = 2.0

    /// Maps each placeholder voice to a name, only where the evidence is
    /// clear. Voices the user already named are left alone and their names are
    /// not given to anyone else.
    static func names(
        for transcript: [TranscriptSegment],
        roster: MeetingRoster
    ) -> [String: String] {
        let spans = highlightSpans(roster.activeSpeakers)
        guard !spans.isEmpty else { return [:] }

        let excluded = excludedNames(transcript: transcript, spans: spans, selfName: roster.selfName)
        let taken = Set(SpeakerNames.speakers(in: transcript).filter { !SpeakerNames.isPlaceholder($0) })

        // Highlighted seconds per placeholder voice, per name.
        var votes: [String: [String: TimeInterval]] = [:]
        for segment in transcript where segment.source == .system {
            guard let speaker = segment.speaker, SpeakerNames.isPlaceholder(speaker) else { continue }
            for span in spans where !excluded.contains(span.name) && !taken.contains(span.name) {
                let shared = overlap(segment, span)
                if shared > 0 { votes[speaker, default: [:]][span.name, default: 0] += shared }
            }
        }

        var candidates: [(speaker: String, name: String, seconds: TimeInterval)] = []
        for (speaker, tally) in votes {
            let ranked = tally.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            guard let best = ranked.first else { continue }
            let total = tally.values.reduce(0, +)
            let runnerUp = ranked.dropFirst().first?.value ?? 0
            guard best.value >= minimumEvidence,
                  best.value >= total * minimumShare,
                  best.value >= runnerUp * minimumLead else { continue }
            candidates.append((speaker, best.key, best.value))
        }

        // Voices sharing a name are numbered in the order they first spoke,
        // which is the order of their placeholders.
        let order = SpeakerNames.speakers(in: transcript)
        var result: [String: String] = [:]
        for name in Set(candidates.map(\.name)) {
            guard let clean = SpeakerNames.sanitized(name) else { continue }
            let voices = candidates.filter { $0.name == name }.map(\.speaker)
                .sorted { (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max) }
            if voices.count == 1 {
                result[voices[0]] = clean
            } else {
                for (index, voice) in voices.enumerated() {
                    result[voice] = SpeakerNames.sharedName(clean, voice: index)
                }
            }
        }
        return result
    }

    /// Applies matched names to every line the matched voices spoke.
    static func named(
        _ transcript: [TranscriptSegment],
        roster: MeetingRoster
    ) -> [TranscriptSegment] {
        var named = transcript
        for (speaker, name) in names(for: transcript, roster: roster) {
            if case .renamed(let renamed) = SpeakerNames.rename(speaker, to: name, in: named) {
                named = renamed
            }
        }
        return named
    }

    /// Names worth offering when the user names a speaker by hand: what the
    /// meeting app listed, then the calendar's invitees, without the user,
    /// without names already in the transcript, and without repeats.
    static func suggestions(
        participants: [String],
        transcript: [TranscriptSegment]
    ) -> [String] {
        let taken = Set(SpeakerNames.speakers(in: transcript).map { $0.lowercased() })
        var seen: Set<String> = []
        return participants.compactMap(SpeakerNames.sanitized).filter { name in
            let key = name.lowercased()
            guard !taken.contains(key), !SpeakerNames.isPlaceholder(name), !seen.contains(key) else {
                return false
            }
            seen.insert(key)
            return true
        }
    }

    // MARK: - Internals

    struct Span: Equatable {
        let start: TimeInterval
        let end: TimeInterval
        let name: String
    }

    /// Turns point readings into spans. Consecutive readings of the same name
    /// join; a reading lasts until the next one or `maximumHold`.
    static func highlightSpans(_ observations: [ActiveSpeakerObservation]) -> [Span] {
        let ordered = observations
            .filter { $0.time.isFinite && $0.time >= 0 && !$0.name.isEmpty }
            .sorted { $0.time < $1.time }
        var spans: [Span] = []
        for (index, reading) in ordered.enumerated() {
            let next = index + 1 < ordered.count ? ordered[index + 1].time : .infinity
            let end = min(next, reading.time + maximumHold)
            guard end > reading.time else { continue }
            if let last = spans.last, last.name == reading.name, last.end >= reading.time {
                spans[spans.count - 1] = Span(start: last.start, end: end, name: last.name)
                continue
            }
            // A new name began about `highlightLag` before Zoom showed it, so
            // the previous span gives up that stretch.
            let start = max(0, reading.time - highlightLag, spans.last?.start ?? 0)
            if let last = spans.last, last.end > start {
                spans[spans.count - 1] = Span(start: last.start, end: start, name: last.name)
            }
            spans.append(Span(start: start, end: end, name: reading.name))
        }
        spans.removeAll { $0.end <= $0.start }
        return spans
    }

    /// Names that are the user's, by the app's own marking or by behaviour.
    /// Zoom only marks "(me)" while its participants panel is open, so the
    /// behaviour is what catches the user the rest of the time.
    static func likelyUserNames(
        in transcript: [TranscriptSegment],
        roster: MeetingRoster
    ) -> Set<String> {
        excludedNames(
            transcript: transcript,
            spans: highlightSpans(roster.activeSpeakers),
            selfName: roster.selfName
        )
    }

    /// The user's own name never goes to a meeting-side voice. Apps mark it
    /// unreliably, so it is also recognised by behaviour: a name highlighted
    /// mostly while the microphone carried speech is the user's.
    private static func excludedNames(
        transcript: [TranscriptSegment],
        spans: [Span],
        selfName: String?
    ) -> Set<String> {
        var microphone: [String: TimeInterval] = [:]
        var system: [String: TimeInterval] = [:]
        for segment in transcript where segment.source != .mixed {
            for span in spans {
                let shared = overlap(segment, span)
                guard shared > 0 else { continue }
                if segment.source == .microphone {
                    microphone[span.name, default: 0] += shared
                } else {
                    system[span.name, default: 0] += shared
                }
            }
        }
        var excluded = Set(microphone.filter { name, seconds in
            seconds >= minimumEvidence && seconds > (system[name] ?? 0)
        }.keys)
        if let selfName { excluded.insert(selfName) }
        return excluded
    }

    private static func overlap(_ segment: TranscriptSegment, _ span: Span) -> TimeInterval {
        let start = segment.startTime
        let end = segment.startTime + segment.duration
        guard start.isFinite, end.isFinite, end > start else { return 0 }
        return max(0, min(end, span.end) - max(start, span.start))
    }
}
