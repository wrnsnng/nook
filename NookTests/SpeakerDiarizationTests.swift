import AVFoundation
import FluidAudio
import Foundation
import Testing
@testable import Nook

/// Locates the test bundle, which holds the audio fixture.
private final class FixtureBundleToken {}

/// The fixture, `Fixtures/two-synthetic-voices.m4a`, is two synthetic macOS
/// voices (`say -v Samantha`, then `say -v Daniel`, then Samantha again)
/// reading invented meeting lines with 0.4 s of silence between turns, encoded
/// as 22.05 kHz AAC so conversion is exercised too. No real recording or person
/// is involved. Ground truth, in seconds: A 0.00 to 5.85, B 6.25 to 13.39,
/// A 13.79 to 20.29.
struct SpeakerDiarizationTests {
    private static var fixture: URL? {
        Bundle(for: FixtureBundleToken.self).url(forResource: "two-synthetic-voices", withExtension: "m4a")
    }

    // MARK: - The real engine

    /// The Nook target's pre-build check refuses to build without the models,
    /// so their absence here means the resource copy broke. That must fail
    /// loudly, not skip.
    @Test
    func theAppBundleCarriesEveryModelTheEngineNeeds() throws {
        let directory = try #require(SpeakerDiarizationService.bundledModelsDirectory)
        #expect(directory.path.hasPrefix(Bundle.main.bundleURL.path))
        #expect(SpeakerDiarizationService().modelsAvailable)
        #expect(try SpeakerDiarizationService.pldaPsi(
            from: directory.appendingPathComponent(SpeakerDiarizationService.ModelFile.pldaParameters)
        ).count == 128)
    }

    /// The models are CC BY 4.0 and FluidAudio carries a BSD notice for
    /// fastcluster; shipping either without its credit breaks the licence.
    @Test
    func theAppBundleCreditsTheEngineAndTheModelAuthors() throws {
        let url = try #require(Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"))
        let notices = try String(contentsOf: url, encoding: .utf8)

        for credit in [
            "FluidAudio 0.17.4", "CC BY 4.0", "creativecommons.org/licenses/by/4.0",
            "pyannote", "WeSpeaker", "BUT Speech@FIT", "Fluid Inference",
            "df2625ac79a7ac6b65ad868fee6d80f320da4232", "Daniel Müllner"
        ] {
            #expect(notices.contains(credit), "THIRD_PARTY_NOTICES.md does not mention \(credit).")
        }
    }

    @Test
    func twoSyntheticVoicesTakingTurnsAreSeparatedAndAlternate() async throws {
        let audio = try #require(Self.fixture, "The synthetic two-voice fixture is missing from the test bundle.")
        let service = SpeakerDiarizationService()
        try #require(service.modelsAvailable, "The app bundle has no diarization models.")

        let turns = try await service.diarize(audioURL: audio)

        #expect(Set(turns.map(\.speaker)).count >= 2)
        #expect(turns.first?.speaker == 0)
        #expect(turns == turns.sorted { $0.start < $1.start })
        #expect(turns.allSatisfy { $0.start >= 0 && $0.end > $0.start && $0.end <= 20.8 })

        // Read the result the way a note will: as passages attributed by
        // overlap. The first and last passage are the same voice, the middle
        // one a different voice.
        let passages = [
            TranscriptSegment(startTime: 0.3, duration: 5.2, text: "Launch checklist.", source: .system),
            TranscriptSegment(startTime: 6.6, duration: 6.4, text: "Release notes.", source: .system),
            TranscriptSegment(startTime: 14.1, duration: 5.9, text: "Screenshots.", source: .system)
        ]
        let labels = SpeakerAttribution.renumberedByFirstAppearance(
            SpeakerAttribution.assign(segments: passages, turns: turns, audio: .systemTrack),
            in: passages
        )
        #expect(passages.map { labels[$0.id] } == [0, 1, 0])
    }

    @Test
    func theModelHubStaysOfflineOnceTheEngineHasRun() async throws {
        let audio = try #require(Self.fixture)
        _ = try await SpeakerDiarizationService().diarize(audioURL: audio)

        #expect(ModelHub.offlineMode)
    }

    @Test
    func silenceYieldsNoTurnsRatherThanAnError() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let silence = try writeTone(in: root, seconds: 3, frequency: 0)

        let turns = try await SpeakerDiarizationService().diarize(audioURL: silence)

        #expect(turns.isEmpty)
    }

    // MARK: - Failure modes

    @Test
    func missingModelsAreReportedBeforeTheAudioIsRead() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SpeakerDiarizationService(modelsDirectory: root)

        #expect(!service.modelsAvailable)
        await #expect(throws: SpeakerDiarizationError.modelsMissing) {
            try await service.diarize(audioURL: root.appendingPathComponent("never-read.m4a"))
        }
        await #expect(throws: SpeakerDiarizationError.modelsMissing) {
            try await SpeakerDiarizationService(modelsDirectory: nil).diarize(audioURL: root)
        }
    }

    @Test
    func aDamagedModelIsReportedAsMissingRatherThanCrashing() async throws {
        let bundled = try #require(SpeakerDiarizationService.bundledModelsDirectory)
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let copy = root.appendingPathComponent("Models")
        try FileManager.default.copyItem(at: bundled, to: copy)
        try Data("not a model".utf8).write(
            to: copy.appendingPathComponent("Embedding.mlmodelc/coremldata.bin")
        )
        let audio = try #require(Self.fixture)

        await #expect(throws: SpeakerDiarizationError.modelsMissing) {
            try await SpeakerDiarizationService(modelsDirectory: copy).diarize(audioURL: audio)
        }
    }

    @Test
    func aFileThatIsNotAudioIsReportedAsUnreadable() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let garbage = root.appendingPathComponent("garbage.m4a")
        try Data("Synthetic bytes that are not audio.".utf8).write(to: garbage)

        await #expect(throws: SpeakerDiarizationError.unreadableAudio) {
            try await SpeakerDiarizationService().diarize(audioURL: garbage)
        }
        await #expect(throws: SpeakerDiarizationError.unreadableAudio) {
            try await SpeakerDiarizationService().diarize(audioURL: root.appendingPathComponent("absent.m4a"))
        }
    }

    @Test
    func aCancelledCallerGetsCancellationNotAResult() async throws {
        let audio = try #require(Self.fixture)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SpeakerDiarizationService().diarize(audioURL: audio)
        }

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    // MARK: - Audio conversion

    @Test
    func audioIsConvertedToSixteenKilohertzMono() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let tone = try writeTone(in: root, seconds: 2, frequency: 440, sampleRate: 44_100)

        let audio = try DiarizationAudio.load(tone)

        #expect(abs(audio.duration - 2) < 0.01)
        #expect(abs(audio.sampleCount - 32_000) < 160)
        #expect(rms(of: audio, from: 0.5, to: 1.5) > 0.1)
    }

    /// Taking only the first channel would lose a remote speaker the call
    /// app placed on the right. Channels must be mixed.
    @Test
    func aVoiceOnlyInTheRightChannelSurvivesConversion() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let rightOnly = try writeTone(in: root, seconds: 1, frequency: 300, sampleRate: 48_000, rightChannelOnly: true)

        let audio = try DiarizationAudio.load(rightOnly)

        #expect(rms(of: audio, from: 0.2, to: 0.8) > 0.05)
    }

    @Test
    func conversionReadsPastTheEndAsNothingRatherThanCrashing() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try DiarizationAudio.load(try writeTone(in: root, seconds: 1, frequency: 440))
        var window = [Float](repeating: 7, count: 100)

        try window.withUnsafeMutableBufferPointer { buffer in
            try audio.copySamples(into: buffer.baseAddress!, offset: audio.sampleCount - 10, count: 100)
        }

        #expect(window[10...].allSatisfy { $0 == 7 })
        try window.withUnsafeMutableBufferPointer { buffer in
            try audio.copySamples(into: buffer.baseAddress!, offset: audio.sampleCount + 5, count: 100)
            try audio.copySamples(into: buffer.baseAddress!, offset: -3, count: 0)
        }
    }

    @Test
    func anEmptyAudioFileIsReportedAsUnreadable() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = try writeTone(in: root, seconds: 0, frequency: 440)

        #expect(throws: SpeakerDiarizationError.unreadableAudio) {
            try DiarizationAudio.load(empty)
        }
    }

    // MARK: - Engine output is not trusted

    @Test
    func speakersAreNumberedByFirstAppearanceWhateverTheEngineCalledThem() {
        let turns = SpeakerDiarizationService.turns(
            from: [
                .init(speakerID: "S3", start: 4, end: 6),
                .init(speakerID: "S1", start: 0, end: 2),
                .init(speakerID: "S2", start: 2, end: 4),
                .init(speakerID: "S1", start: 6, end: 8)
            ],
            audioDuration: 10
        )

        #expect(turns == [
            SpeakerTurn(start: 0, end: 2, speaker: 0),
            SpeakerTurn(start: 2, end: 4, speaker: 1),
            SpeakerTurn(start: 4, end: 6, speaker: 2),
            SpeakerTurn(start: 6, end: 8, speaker: 0)
        ])
    }

    @Test
    func implausibleEngineTurnsAreDroppedOrClampedToTheAudio() {
        let turns = SpeakerDiarizationService.turns(
            from: [
                .init(speakerID: "S9", start: .nan, end: 3),
                .init(speakerID: "S9", start: 1, end: .infinity),
                .init(speakerID: "S9", start: 5, end: 4),
                .init(speakerID: "S9", start: 12, end: 14),
                .init(speakerID: "S2", start: -1, end: 1),
                .init(speakerID: "S1", start: 8, end: 11)
            ],
            audioDuration: 10
        )

        #expect(turns == [
            SpeakerTurn(start: 0, end: 1, speaker: 0),
            SpeakerTurn(start: 8, end: 10, speaker: 1)
        ])
        #expect(SpeakerDiarizationService.turns(
            from: [.init(speakerID: "S1", start: 0, end: 1)], audioDuration: .nan
        ).isEmpty)
    }

    @Test
    func malformedPLDAParametersAreRejected() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let short = root.appendingPathComponent("short.json")
        try Data(#"{"tensors":{"psi":{"data_base64":"AAAAAA=="}}}"#.utf8).write(to: short)
        let notJSON = root.appendingPathComponent("broken.json")
        try Data("{".utf8).write(to: notJSON)

        #expect(throws: SpeakerDiarizationError.modelsMissing) {
            try SpeakerDiarizationService.pldaPsi(from: short)
        }
        #expect(throws: (any Error).self) {
            try SpeakerDiarizationService.pldaPsi(from: notJSON)
        }
    }

    // MARK: - Helpers

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NookSpeakerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A stereo WAV with a sine tone (or silence when `frequency` is 0).
    private func writeTone(
        in directory: URL,
        seconds: Double,
        frequency: Double,
        sampleRate: Double = 44_100,
        rightChannelOnly: Bool = false
    ) throws -> URL {
        let url = directory.appendingPathComponent("tone-\(UUID().uuidString).wav")
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false
        ))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false
        )
        let frames = AVAudioFrameCount(seconds * sampleRate)
        guard frames > 0 else { return url }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let left = try #require(buffer.floatChannelData?[0])
        let right = try #require(buffer.floatChannelData?[1])
        for frame in 0..<Int(frames) {
            let value = Float(0.5 * sin(2 * Double.pi * frequency * Double(frame) / sampleRate))
            left[frame] = rightChannelOnly ? 0 : value
            right[frame] = value
        }
        try file.write(from: buffer)
        return url
    }

    private func rms(of audio: DiarizationAudio, from start: TimeInterval, to end: TimeInterval) -> Float {
        let first = Int(start * Double(DiarizationAudio.sampleRate))
        let count = Int((end - start) * Double(DiarizationAudio.sampleRate))
        var samples = [Float](repeating: 0, count: count)
        samples.withUnsafeMutableBufferPointer { buffer in
            try? audio.copySamples(into: buffer.baseAddress!, offset: first, count: count)
        }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, count))).squareRoot()
    }
}
