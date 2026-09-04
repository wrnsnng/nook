import AVFoundation
import Foundation
import Testing
@testable import Nook

/// Synthetic frequencies prove what survived the exported file. No microphone,
/// speech model, real meeting or hardware playback participates in these tests.
struct AudioExtractionTests {
    @MainActor @Test(arguments: [false, true], [false, true])
    func recoveryIncludesResumedPrimaryAudioEvenWithoutACompletedCompanion(
        unfinishedCompanion: Bool, exportFails: Bool
    ) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MarkdownStore(noteLoader: { _, _ in .success((notes: [], issues: [])) })
        store.storageURL = root
        let recordings = store.recordingsDirectory()
        let id = UUID()
        let first = recordings.appendingPathComponent("\(id.uuidString).mp4")
        let second = recordings.appendingPathComponent("\(id.uuidString).part-2.mp4")
        let firstFixture = try await capture(in: root, tones: [Tone(440)])
        let secondFixture = try await capture(in: root, tones: [Tone(880)])
        try FileManager.default.moveItem(at: firstFixture, to: first)
        try FileManager.default.moveItem(at: secondFixture, to: second)
        let expectedDuration = try await duration(of: first) + duration(of: second)
        let originalBytes = try [first, second].map { try Data(contentsOf: $0) }
        let cached = recordings.appendingPathComponent("\(id.uuidString).m4a")
        try await AudioExtractor.extractAudio(from: first, to: cached)
        let cachedBytes = try Data(contentsOf: cached)
        let package = SourceAudioFiles.directory(for: second)
        if unfinishedCompanion {
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
            try Data("Unfinished synthetic source audio".utf8).write(to: SourceAudioFiles.audio(in: package))
        }
        #expect(SourceAudioFiles.completedAudio(for: first) == nil)
        #expect(SourceAudioFiles.completedAudio(for: second) == nil)
        var extractions = 0
        var transcriptions = 0
        let recovery = RecordingRecovery(store: store, extractAudio: { sources, destination in
            extractions += 1
            #expect(sources == [first, second])
            if exportFails {
                try await AudioExtractor.extractAudio(from: sources, to: destination, export: { _, _, _ in
                    throw AudioExtractionError.invalidExport
                })
            } else {
                try await AudioExtractor.extractAudio(from: sources, to: destination)
            }
        }, transcribeAudio: { url, _ in
            transcriptions += 1
            let audio = try decoded(url)
            #expect(abs(audio.duration - expectedDuration) < 0.05)
            #expect(audio.amplitude(440, from: 0.15, to: 0.85) > 0.2)
            let hasResumedAudio = audio.amplitude(880, from: 1.15, to: 1.85) > 0.2
            #expect(hasResumedAudio)
            return [TranscriptSegment(startTime: 0.1, duration: 0.1, text: "First sitting.")]
                + (hasResumedAudio ? [TranscriptSegment(startTime: 1.1, duration: 0.1, text: "Resumed sitting.")] : [])
        }, summarizeTranscript: { transcript, title in
            SummaryService.fallbackInsights(transcript: transcript, fallbackTitle: title)
        })
        recovery.scan()
        recovery.recover(try #require(recovery.orphans.first { $0.id == id }), localeIdentifier: "en_US")
        await recovery.recoveryTaskForTesting?.value
        #expect(extractions == 1)
        if exportFails {
            #expect(transcriptions == 0)
            #expect(store.uniqueNote(id: id) == nil)
            #expect(try Data(contentsOf: cached) == cachedBytes)
            #expect(try [first, second].map { try Data(contentsOf: $0) } == originalBytes)
            #expect(!unfinishedCompanion || FileManager.default.fileExists(atPath: package.path))
        } else {
            #expect(transcriptions == 1)
            let note = try #require(store.uniqueNote(id: id))
            await store.summarySessions.session(for: note).waitForCompletion()
            #expect(note.transcript.map(\.text).joined(separator: " ") == "First sitting. Resumed sitting.")
            #expect(note.transcript.allSatisfy { $0.source == .mixed })
            #expect(!FileManager.default.fileExists(atPath: first.path))
            #expect(!FileManager.default.fileExists(atPath: second.path))
            #expect(!FileManager.default.fileExists(atPath: package.path))
        }
    }

    @Test(arguments: [false, true])
    func everyTrackSurvivesEveryResumedPart(decreasingTrackCount: Bool) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstFrequencies: [Double] = decreasingTrackCount ? [1_320, 1_760, 2_200] : [440, 880]
        let secondFrequencies: [Double] = decreasingTrackCount ? [440, 880] : [1_320, 1_760, 2_200]
        let first = try await capture(in: root, tones: firstFrequencies.map { Tone($0) })
        let second = try await capture(in: root, tones: secondFrequencies.map { Tone($0) })
        let output = root.appendingPathComponent("result.m4a")
        try await AudioExtractor.extractAudio(from: [first, second], to: output)
        let audio = try decoded(output)
        let firstDuration = try await duration(of: first)
        let expectedDuration = firstDuration + (try await duration(of: second))
        #expect(abs(audio.duration - expectedDuration) < 0.05)
        #expect(abs(try await duration(of: output) - expectedDuration) < 0.005)
        for frequency in firstFrequencies {
            #expect(abs(audio.amplitude(frequency, from: 0.15, to: 0.85) - 0.4 / Double(firstFrequencies.count)) < 0.04)
            #expect(audio.amplitude(frequency, from: firstDuration + 0.15, to: firstDuration + 0.85) < 0.02)
        }
        for frequency in secondFrequencies {
            #expect(abs(audio.amplitude(frequency, from: firstDuration + 0.15, to: firstDuration + 0.85) - 0.4 / Double(secondFrequencies.count)) < 0.04)
            #expect(audio.amplitude(frequency, from: 0.15, to: 0.85) < 0.02)
        }
        #expect(audio.samples.allSatisfy { abs($0) < 0.99 })
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test
    func singleCaptureMixesEveryTrackAndBothStereoChannels() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await capture(in: root, tones: [Tone(440, right: 880), Tone(1_320)])
        let output = root.appendingPathComponent("result.m4a")
        try await AudioExtractor.extractAudio(from: source, to: output)
        let audio = try decoded(output)
        for frequency in [440.0, 880, 1_320] {
            #expect(audio.amplitude(frequency, from: 0.15, to: 0.85) > 0.035)
        }
        #expect(abs(audio.duration - 1) < 0.05)
    }

    @Test
    func aCompleteVerifiedExportReplacesOldAudioWithoutChangingItsSource() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await capture(in: root, tones: [Tone(440)])
        let sourceBytes = try Data(contentsOf: source)
        let output = root.appendingPathComponent("result.m4a")
        try Data("Old audio".utf8).write(to: output)
        try await AudioExtractor.extractAudio(from: source, to: output)
        #expect(try Data(contentsOf: source) == sourceBytes)
        #expect(try decoded(output).amplitude(440, from: 0.15, to: 0.85) > 0.2)
    }

    @Test
    func trackOffsetsAndPartBoundariesKeepTheirOriginalTiming() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await capture(in: root, tones: [
            Tone(440, duration: 1.5), Tone(880, start: 0.5, duration: 0.5)
        ])
        let second = try await capture(in: root, tones: [Tone(1_320, start: 0.25, duration: 1.25)])
        let output = root.appendingPathComponent("result.m4a")
        try await AudioExtractor.extractAudio(from: [first, second], to: output)
        let audio = try decoded(output)
        let firstDuration = try await duration(of: first)
        let expectedDuration = firstDuration + (try await duration(of: second))
        #expect(abs(audio.duration - expectedDuration) < 0.05)
        #expect(abs(try await duration(of: output) - expectedDuration) < 0.005)
        #expect(audio.amplitude(880, from: 0.1, to: 0.4) < 0.02)
        #expect(audio.amplitude(880, from: 0.6, to: 0.9) > 0.07)
        #expect(audio.amplitude(880, from: 1.1, to: 1.4) < 0.02)
        #expect(audio.amplitude(1_320, from: firstDuration + 0.05, to: firstDuration + 0.2) < 0.02)
        #expect(audio.amplitude(1_320, from: firstDuration + 0.35, to: firstDuration + 1.2) > 0.2)
    }

    @Test(arguments: [false, true])
    func silentEndsOfCapturePartsAreNotRemoved(resumed: Bool) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await capture(in: root, tones: [Tone(440)], trailingSilence: 0.5)
        let second = try await capture(in: root, tones: [Tone(880)])
        let firstDuration = try await duration(of: first)
        try #require(firstDuration > 1.45, "The input fixture must preserve its silent tail")
        let firstAsset = AVURLAsset(url: first)
        let audioTracks = try await firstAsset.loadTracks(withMediaType: .audio)
        let audioEnd = try await #require(audioTracks.first).load(.timeRange).end.seconds
        try #require(firstDuration - audioEnd > 0.4, "Video must outlast the actual audio track")
        let output = root.appendingPathComponent("result.m4a")
        try await AudioExtractor.extractAudio(from: resumed ? [first, second] : [first], to: output)
        let expectedDuration = resumed ? firstDuration + (try await duration(of: second)) : firstDuration
        #expect(abs(try await duration(of: output) - expectedDuration) < 0.005)
        let audio = try decoded(output)
        #expect(audio.amplitude(440, from: 1.15, to: 1.4) < 0.02)
        #expect(audio.amplitude(880, from: 1.15, to: 1.4) < 0.02)
        #expect(abs(audio.duration - expectedDuration) < 0.05)
        if resumed {
            #expect(audio.amplitude(880, from: firstDuration + 0.15, to: firstDuration + 0.85) > 0.2)
        }
    }

    @Test(arguments: ["missing", "corrupt", "empty input"])
    func anInvalidPartCannotSilentlyShortenOrReplaceTheRecording(kind: String) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = try await capture(in: root, tones: [Tone(440)])
        let invalid = root.appendingPathComponent("invalid.mp4")
        if kind == "corrupt" { try Data("Not audio".utf8).write(to: invalid) }
        let output = root.appendingPathComponent("result.m4a")
        let original = Data("Existing complete recording".utf8)
        try original.write(to: output)
        await #expect(throws: (any Error).self) {
            try await AudioExtractor.extractAudio(from: kind == "empty input" ? [] : [valid, invalid], to: output)
        }
        #expect(try Data(contentsOf: output) == original)
        #expect(FileManager.default.fileExists(atPath: valid.path))
    }

    @Test(arguments: ["same path", "hard link", "symbolic link"])
    func anOutputAliasCannotReplaceItsOwnSource(kind: String) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await capture(in: root, tones: [Tone(440)])
        let original = try Data(contentsOf: source)
        let output: URL
        if kind == "same path" { output = source }
        else {
            output = root.appendingPathComponent("alias.m4a")
            if kind == "hard link" { try FileManager.default.linkItem(at: source, to: output) }
            else { try FileManager.default.createSymbolicLink(at: output, withDestinationURL: source) }
        }
        await #expect(throws: (any Error).self) {
            try await AudioExtractor.extractAudio(from: source, to: output)
        }
        #expect(try Data(contentsOf: source) == original)
        #expect(try Data(contentsOf: output) == original)
    }

    @Test
    func exportFailureKeepsTheOldAudioAndRemovesItsPrivateIntermediate() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await capture(in: root, tones: [Tone(440)])
        let output = root.appendingPathComponent("result.m4a")
        let original = Data("Existing complete recording".utf8)
        try original.write(to: output)
        let probe = ExtractionProbe()
        await #expect(throws: (any Error).self) {
            try await AudioExtractor.extractAudio(from: [source], to: output, export: { _, _, staged in
                await probe.record(staged)
                let directory = staged.deletingLastPathComponent()
                let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
                #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
                try Data("Partial export".utf8).write(to: staged)
                throw CocoaError(.fileWriteUnknown)
            })
        }
        #expect(try Data(contentsOf: output) == original)
        let staged = try #require(await probe.url)
        #expect(!FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
    }

    @Test
    func cancellationAfterExportStartsCannotPublishPartialAudio() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await capture(in: root, tones: [Tone(440)])
        let output = root.appendingPathComponent("result.m4a")
        let original = Data("Existing complete recording".utf8)
        try original.write(to: output)
        let probe = ExtractionProbe()
        let task = Task {
            try await AudioExtractor.extractAudio(from: [source], to: output, export: { _, _, staged in
                try Data("Partial export".utf8).write(to: staged)
                await probe.suspend(staged)
            })
        }
        for _ in 0..<200 {
            if await probe.url != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let staged = await probe.url
        task.cancel()
        await probe.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: output) == original)
        #expect(staged != nil)
        if let staged { #expect(!FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path)) }
    }

    @Test
    func failedTemporaryCleanupIsReportedWithTheRetainedLocation() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await capture(in: root, tones: [Tone(440)])
        let output = root.appendingPathComponent("result.m4a")
        let probe = ExtractionProbe()
        do {
            try await AudioExtractor.extractAudio(from: [source], to: output, export: { _, _, staged in
                await probe.record(staged)
                try Data("Partial export".utf8).write(to: staged)
                throw CocoaError(.fileWriteUnknown)
            }, cleanup: { _ in throw CocoaError(.fileWriteNoPermission) })
            Issue.record("Failed cleanup must not report success")
        } catch AudioExtractionError.cleanupFailed(let directory) {
            defer { try? FileManager.default.removeItem(at: directory) }
            let staged = try #require(await probe.url)
            #expect(directory == staged.deletingLastPathComponent())
            #expect(FileManager.default.fileExists(atPath: staged.path))
            #expect(AudioExtractionError.cleanupFailed(directory).localizedDescription.contains(directory.path))
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test(arguments: ["corrupt", "short audio", "video only"])
    func anUnusableExportCannotReplacePreviousAudio(kind: String) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await capture(in: root, tones: [Tone(440)])
        let invalid = root.appendingPathComponent(kind == "video only" ? "invalid.mov" : "invalid.m4a")
        switch kind {
        case "short audio": try writeTone(Tone(880, duration: 0.25), to: invalid)
        case "video only": try await writeVideo(to: invalid, duration: 1)
        default: try Data("Invalid export".utf8).write(to: invalid)
        }
        let output = root.appendingPathComponent("result.m4a")
        let original = Data("Previous complete audio".utf8)
        try original.write(to: output)
        let probe = ExtractionProbe()
        await #expect(throws: (any Error).self) {
            try await AudioExtractor.extractAudio(from: [source], to: output, export: { _, _, staged in
                await probe.record(staged)
                try FileManager.default.copyItem(at: invalid, to: staged)
            })
        }
        #expect(try Data(contentsOf: output) == original)
        let staged = try #require(await probe.url)
        #expect(!FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
    }

    @Test(arguments: ["source", "destination", "new destination"])
    func filesChangedDuringExportAreNeverOverwritten(changed: String) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await capture(in: root, tones: [Tone(440)])
        let exported = root.appendingPathComponent("complete.m4a")
        try await AudioExtractor.extractAudio(from: source, to: exported)
        let output = root.appendingPathComponent("result.m4a")
        let original = Data("Existing complete recording".utf8)
        if changed != "new destination" { try original.write(to: output) }
        let external = Data("External replacement".utf8)
        await #expect(throws: (any Error).self) {
            try await AudioExtractor.extractAudio(from: [source], to: output, export: { _, _, staged in
                try FileManager.default.copyItem(at: exported, to: staged)
                try external.write(to: changed == "source" ? source : output, options: .atomic)
            })
        }
        #expect(try Data(contentsOf: output) == (changed == "source" ? original : external))
    }

    private struct Tone {
        let frequency: Double
        let right: Double?
        let start: Double
        let duration: Double
        init(_ frequency: Double, right: Double? = nil, start: Double = 0, duration: Double = 1) {
            self.frequency = frequency
            self.right = right
            self.start = start
            self.duration = duration
        }
    }

    /// AAC tracks in a real MOV container retain separate channels/tracks.
    /// Fixture checks fail if passthrough ever flattens them before extraction.
    private func capture(in root: URL, tones: [Tone], trailingSilence: Double = 0) async throws -> URL {
        let composition = AVMutableComposition()
        var assets: [AVURLAsset] = []
        defer { withExtendedLifetime(assets) {} }
        for tone in tones {
            let url = root.appendingPathComponent(UUID().uuidString + ".m4a")
            try writeTone(tone, to: url)
            // AVAssetTrack.asset is weak. The input assets must outlive the
            // tracks while the synthetic composition is built and exported.
            let asset = AVURLAsset(url: url)
            assets.append(asset)
            let source = try #require(try await asset.loadTracks(withMediaType: .audio).first)
            let track = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
            do {
                try track.insertTimeRange(
                    CMTimeRange(start: .zero, duration: CMTime(seconds: tone.duration, preferredTimescale: 48_000)),
                    of: source, at: CMTime(seconds: tone.start, preferredTimescale: 48_000)
                )
            } catch { throw FixtureFailure(stage: "inserting synthetic track", underlying: error) }
        }
        if trailingSilence > 0 {
            // Passthrough drops an empty tail in an audio-only composition.
            // Real capture has video, so make actual video samples that outlast
            // the audio instead of assuming an empty edit survives muxing.
            let videoURL = root.appendingPathComponent(UUID().uuidString + ".mov")
            try await writeVideo(to: videoURL, duration: composition.duration.seconds + trailingSilence)
            let videoAsset = AVURLAsset(url: videoURL)
            assets.append(videoAsset)
            let source = try #require(try await videoAsset.loadTracks(withMediaType: .video).first)
            let track = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
            try track.insertTimeRange(try await source.load(.timeRange), of: source, at: .zero)
        }
        let destination = root.appendingPathComponent(UUID().uuidString + ".mov")
        let export = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        do { try await export.export(to: destination, as: .mov) }
        catch { throw FixtureFailure(stage: "exporting synthetic capture", underlying: error) }
        let tracks = try await AVURLAsset(url: destination).loadTracks(withMediaType: .audio)
        try #require(tracks.count == tones.count, "Synthetic input must actually contain each separate audio track")
        return destination
    }

    private func writeVideo(to url: URL, duration: Double) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 16, kCVPixelBufferHeightKey as String: 16
        ])
        try #require(writer.canAdd(input))
        writer.add(input)
        try #require(writer.startWriting())
        defer { if writer.status == .writing { writer.cancelWriting() } }
        writer.startSession(atSourceTime: .zero)
        var optionalBuffer: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
                                        nil, &optionalBuffer) == kCVReturnSuccess)
        let buffer = try #require(optionalBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        let pixels = try #require(CVPixelBufferGetBaseAddress(buffer))
        memset(pixels, 0, CVPixelBufferGetBytesPerRow(buffer) * 16)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let frameCount = Int(ceil(duration * 10))
        for frame in 0..<frameCount {
            for _ in 0..<1_000 {
                if input.isReadyForMoreMediaData || writer.status != .writing { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            try #require(input.isReadyForMoreMediaData)
            try #require(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(frameCount), timescale: 10))
        await writer.finishWriting()
        try #require(writer.status == .completed)
    }

    private struct FixtureFailure: Error, CustomStringConvertible {
        let stage: String
        let underlying: any Error
        var description: String { "Failed while \(stage): \(underlying)" }
    }

    private func writeTone(_ tone: Tone, to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: tone.right == nil ? 1 : 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(tone.duration * 48_000)))
        buffer.frameLength = buffer.frameCapacity
        let channels = try #require(buffer.floatChannelData)
        for channel in 0..<Int(format.channelCount) {
            let frequency = channel == 0 ? tone.frequency : (tone.right ?? tone.frequency)
            for frame in 0..<Int(buffer.frameLength) {
                channels[channel][frame] = Float(0.4 * sin(2 * .pi * frequency * Double(frame) / 48_000))
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: format.channelCount, AVEncoderBitRateKey: 192_000
        ])
        try file.write(from: buffer)
    }

    private struct DecodedAudio {
        let samples: [Float]
        let sampleRate: Double
        var duration: Double { Double(samples.count) / sampleRate }
        func amplitude(_ frequency: Double, from start: Double, to end: Double) -> Double {
            let lower = max(0, Int(start * sampleRate))
            let upper = min(samples.count, Int(end * sampleRate))
            guard upper > lower else { return 0 }
            var real = 0.0
            var imaginary = 0.0
            for frame in lower..<upper {
                let phase = 2 * Double.pi * frequency * Double(frame) / sampleRate
                real += Double(samples[frame]) * cos(phase)
                imaginary += Double(samples[frame]) * sin(phase)
            }
            return 2 * hypot(real, imaginary) / Double(upper - lower)
        }
    }

    private func decoded(_ url: URL) throws -> DecodedAudio {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channels = try #require(buffer.floatChannelData)
        let samples = (0..<Int(buffer.frameLength)).map { frame in
            (0..<Int(format.channelCount)).reduce(Float(0)) { $0 + channels[$1][frame] } / Float(format.channelCount)
        }
        return DecodedAudio(samples: samples, sampleRate: format.sampleRate)
    }

    private func duration(of url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NookExtractionTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private actor ExtractionProbe {
    private(set) var url: URL?
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func record(_ url: URL) { self.url = url }
    func suspend(_ url: URL) async {
        self.url = url
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func resume() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
