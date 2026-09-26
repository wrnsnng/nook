import Foundation
import Testing
@testable import Nook

/// Attribution only ever reports overlap between two timelines. These tests
/// hold it to that: no voice is guessed for a passage the turns do not cover,
/// the user's own passages are never given to someone else, and the same
/// input always produces the same labels.
struct SpeakerAttributionTests {
    private func passage(
        _ start: TimeInterval,
        _ duration: TimeInterval,
        _ source: TranscriptSegment.Source = .system
    ) -> TranscriptSegment {
        TranscriptSegment(startTime: start, duration: duration, text: "Synthetic passage.", source: source)
    }

    private func turn(_ start: TimeInterval, _ end: TimeInterval, _ speaker: Int) -> SpeakerTurn {
        SpeakerTurn(start: start, end: end, speaker: speaker)
    }

    @Test
    func aMeetingPassageGoesToTheSpeakerWhoCoversMostOfIt() {
        let first = passage(0, 4)
        let second = passage(5, 4)
        let turns = [turn(0, 5.5, 0), turn(5.5, 10, 1)]

        let result = SpeakerAttribution.assign(segments: [first, second], turns: turns, audio: .systemTrack)

        #expect(result == [first.id: 0, second.id: 1])
    }

    @Test
    func severalShortTurnsBySameSpeakerOutweighOneLongerTurnByAnother() {
        let line = passage(0, 5)
        // Speaker 0 speaks twice for 1.2 s each; speaker 1 once for 2 s.
        let turns = [turn(0, 1.2, 0), turn(1.4, 3.4, 1), turn(3.6, 4.8, 0)]

        let result = SpeakerAttribution.assign(segments: [line], turns: turns, audio: .systemTrack)

        #expect(result[line.id] == 0)
    }

    @Test
    func equalOverlapGoesToTheSpeakerAlreadyTalkingWhenThePassageBegan() {
        let line = passage(2, 4)
        // Two seconds each, but speaker 1 was talking when the passage began.
        let turns = [turn(4, 10, 0), turn(0, 4, 1)]

        let result = SpeakerAttribution.assign(segments: [line], turns: turns, audio: .systemTrack)

        #expect(result[line.id] == 1)
    }

    @Test
    func equalOverlapStartingTogetherGoesToTheLowerNumberEveryTime() {
        let line = passage(0, 2)
        // Overlapping output is not expected from the engine, but a tie must
        // still resolve the same way regardless of input order.
        let turns = [turn(0, 1, 2), turn(0, 1, 1)]

        for ordering in [turns, turns.reversed()] {
            let result = SpeakerAttribution.assign(segments: [line], turns: ordering, audio: .systemTrack)
            #expect(result[line.id] == 1)
        }
    }

    @Test
    func aPassageNoTurnTouchesStaysUnassigned() {
        let covered = passage(0, 2)
        let adjacent = passage(3, 2) // Starts exactly where the turn ends.
        let silent = passage(20, 2)
        let turns = [turn(0, 3, 0)]

        let result = SpeakerAttribution.assign(
            segments: [covered, adjacent, silent], turns: turns, audio: .systemTrack
        )

        #expect(result == [covered.id: 0])
    }

    @Test
    func noTurnsAtAllLeaveEveryPassageUnassigned() {
        let result = SpeakerAttribution.assign(
            segments: [passage(0, 2), passage(3, 2)], turns: [], audio: .systemTrack
        )

        #expect(result.isEmpty)
    }

    @Test(arguments: [SpeakerAttribution.DiarizedAudio.systemTrack, .mixedRecording])
    func theUsersOwnPassagesAreNeverAttributedToAnyone(audio: SpeakerAttribution.DiarizedAudio) {
        let mine = passage(0, 4, .microphone)
        let theirs = passage(4, 4, .system)
        let turns = [turn(0, 8, 0)]

        let result = SpeakerAttribution.assign(segments: [mine, theirs], turns: turns, audio: audio)

        #expect(result[mine.id] == nil)
        #expect(result[theirs.id] == 0)
    }

    @Test
    func mixedPassagesAreAttributedOnlyWhenTheMixedRecordingWasSeparated() {
        let unknown = passage(0, 4, .mixed)
        let turns = [turn(0, 4, 0)]

        let fromSystemTrack = SpeakerAttribution.assign(segments: [unknown], turns: turns, audio: .systemTrack)
        let fromMixedRecording = SpeakerAttribution.assign(segments: [unknown], turns: turns, audio: .mixedRecording)

        #expect(fromSystemTrack.isEmpty)
        #expect(fromMixedRecording == [unknown.id: 0])
    }

    @Test
    func aZeroLengthPassageBelongsToTheTurnItFallsInside() {
        let instant = passage(6, 0)
        let atBoundary = passage(5, 0)
        let turns = [turn(0, 5, 0), turn(5, 10, 1)]

        let result = SpeakerAttribution.assign(segments: [instant, atBoundary], turns: turns, audio: .systemTrack)

        #expect(result[instant.id] == 1)
        #expect(result[atBoundary.id] == 1)
    }

    @Test
    func implausibleTurnsFromTheModelAreIgnored() {
        let line = passage(0, 4)
        let turns = [
            turn(.nan, 4, 3),
            turn(0, .infinity, 3),
            turn(-2, 4, 3),
            turn(3, 1, 3),
            turn(0, 4, -1),
            turn(1, 2, 0)
        ]

        let result = SpeakerAttribution.assign(segments: [line], turns: turns, audio: .systemTrack)

        #expect(result == [line.id: 0])
    }

    @Test
    func aPassageWithImpossibleTimingIsLeftUnassigned() {
        let broken = passage(.nan, 2)
        let backwards = passage(4, -3)

        let result = SpeakerAttribution.assign(
            segments: [broken, backwards], turns: [turn(0, 10, 0)], audio: .systemTrack
        )

        #expect(result.isEmpty)
    }

    @Test
    func renumberingCountsUpInTheOrderSpeakersFirstAppearInTheTranscript() {
        let first = passage(10, 2)
        let second = passage(0, 2)
        let third = passage(20, 2)
        let fourth = passage(30, 2)
        let assignments = [first.id: 4, second.id: 7, third.id: 4, fourth.id: 2]

        let result = SpeakerAttribution.renumberedByFirstAppearance(
            assignments, in: [first, second, third, fourth]
        )

        #expect(result == [second.id: 0, first.id: 1, third.id: 1, fourth.id: 2])
    }

    @Test
    func renumberingKeepsTranscriptOrderForPassagesThatStartTogether() {
        let you = passage(5, 2, .microphone)
        let first = passage(5, 2)
        let second = passage(5, 2)
        let assignments = [first.id: 3, second.id: 1]

        let result = SpeakerAttribution.renumberedByFirstAppearance(assignments, in: [you, first, second])

        #expect(result == [first.id: 0, second.id: 1])
        #expect(result[you.id] == nil)
    }

    @Test
    func attributionThenRenumberingLabelsAConversationInReadingOrder() {
        let lines = [
            passage(2, 3), passage(5, 2, .microphone), passage(7, 3), passage(10, 3)
        ]
        // The engine numbered speakers by the audio, where speaker 0 said a
        // few words at the start that no transcript passage covers. In the
        // transcript, speaker 1 is heard first.
        let turns = [turn(0, 1.5, 0), turn(2, 5, 1), turn(7, 10, 0), turn(10, 13, 1)]

        let result = SpeakerAttribution.renumberedByFirstAppearance(
            SpeakerAttribution.assign(segments: lines, turns: turns, audio: .systemTrack), in: lines
        )

        #expect(result == [lines[0].id: 0, lines[2].id: 1, lines[3].id: 0])
    }
}
