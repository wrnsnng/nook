import AVFoundation
import Foundation
import Testing
@testable import Nook

private final class SeparationFixtureToken {}

/// The finished-recording step that labels the meeting side of a transcript,
/// run against a real capture file with labelled source tracks and the real
/// bundled engine.
@MainActor
struct MeetingSpeakerSeparationTests {
    private static var voices: URL? {
        Bundle(for: SeparationFixtureToken.self)
            .url(forResource: "two-synthetic-voices", withExtension: "m4a")
    }

    /// Passages as the recording's transcription would place them: two
    /// voices taking turns on the meeting side, and the user in between.
    private func transcript() -> [TranscriptSegment] {
        [
            TranscriptSegment(startTime: 0.3, duration: 5.2, text: "Launch checklist.", source: .system),
            TranscriptSegment(startTime: 6.0, duration: 0.8, text: "Okay.", source: .microphone),
            TranscriptSegment(startTime: 6.6, duration: 6.4, text: "Release notes.", source: .system),
            TranscriptSegment(startTime: 14.1, duration: 5.9, text: "Screenshots.", source: .system),
        ]
    }

    /// The meeting side is separated and labelled in order of appearance;
    /// the user's own line is never given to a speaker.
    @Test
    func aFinishedRecordingLabelsTheMeetingSideVoices() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = try await labelledCapture(in: root, systemSource: .system)

        let labelled = await MeetingSpeakerSeparation.labelled(
            transcript(), recordingURLs: [capture], isEnabled: true
        )

        #expect(labelled.map(\.speaker) == ["Speaker 1", nil, "Speaker 2", "Speaker 1"])
        #expect(labelled[1].speakerLabel == "You")
    }

    /// Without a labelled system track, separating would count the user's
    /// own voice as a speaker, so nothing is labelled.
    @Test
    func aRecordingWithoutALabelledMeetingTrackIsLeftAsItWas() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = try await labelledCapture(in: root, systemSource: nil)

        let original = transcript()
        let labelled = await MeetingSpeakerSeparation.labelled(
            original, recordingURLs: [capture], isEnabled: true
        )
        #expect(labelled == original)
    }

    /// Turning the setting off keeps "Meeting" and reads no audio at all.
    @Test
    func turningSeparationOffKeepsTheTranscript() async throws {
        let original = transcript()
        let labelled = await MeetingSpeakerSeparation.labelled(
            original,
            recordingURLs: [URL(fileURLWithPath: "/nonexistent/capture.mov")],
            isEnabled: false
        )
        #expect(labelled == original)
    }

    /// A capture that cannot be read never costs the meeting its note.
    @Test
    func anUnreadableRecordingLeavesTheTranscriptUnchanged() async throws {
        let original = transcript()
        let labelled = await MeetingSpeakerSeparation.labelled(
            original,
            recordingURLs: [URL(fileURLWithPath: "/nonexistent/capture.mov")],
            isEnabled: true
        )
        #expect(labelled == original)
    }

    // MARK: - Fixtures

    /// A capture as `SourceAudioRecording` writes one: the synthetic voices
    /// on one track, marked with `systemSource`, beside a silent microphone
    /// track. A nil source writes an unlabelled track, as older captures had.
    private func labelledCapture(
        in root: URL,
        systemSource: TranscriptSegment.Source?
    ) async throws -> URL {
        let voices = try #require(Self.voices, "The synthetic two-voice fixture is missing.")
        let destination = root.appendingPathComponent("capture.mov")
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)

        let silence = root.appendingPathComponent("silence.caf")
        try writeSilence(seconds: 21, to: silence)

        let sources: [(URL, TranscriptSegment.Source?)] = [
            (voices, systemSource),
            (silence, .microphone),
        ]
        var assets: [AVURLAsset] = []
        defer { withExtendedLifetime(assets) {} }
        var readers: [AVAssetReader] = []
        var outputs: [AVAssetReaderTrackOutput] = []
        var inputs: [AVAssetWriterInput] = []
        for (url, source) in sources {
            let asset = AVURLAsset(url: url)
            assets.append(asset)
            let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            ])
            reader.add(output)
            readers.append(reader)
            outputs.append(output)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000,
            ])
            if let source { input.metadata = [RecordedAudioSource.metadata(for: source)] }
            try #require(writer.canAdd(input))
            writer.add(input)
            inputs.append(input)
        }
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for reader in readers { try #require(reader.startReading()) }
        // The writer interleaves tracks and stops accepting one until the
        // other catches up, so both are fed in step rather than one after
        // the other.
        var pending: [CMSampleBuffer?] = outputs.map { $0.copyNextSampleBuffer() }
        var finished = pending.map { $0 == nil }
        for index in finished.indices where finished[index] { inputs[index].markAsFinished() }
        var idleRounds = 0
        while finished.contains(false) {
            var progressed = false
            for index in sources.indices where !finished[index] && inputs[index].isReadyForMoreMediaData {
                guard let buffer = pending[index] else { continue }
                try #require(inputs[index].append(buffer))
                progressed = true
                pending[index] = outputs[index].copyNextSampleBuffer()
                if pending[index] == nil {
                    finished[index] = true
                    inputs[index].markAsFinished()
                }
            }
            if progressed {
                idleRounds = 0
            } else {
                idleRounds += 1
                try #require(idleRounds < 5_000, "The capture writer stopped accepting audio.")
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        await writer.finishWriting()
        try #require(writer.status == .completed)
        return destination
    }

    private func writeSilence(seconds: Double, to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 48_000))
        )
        buffer.frameLength = buffer.frameCapacity
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingSpeakerSeparationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
