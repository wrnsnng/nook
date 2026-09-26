import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import Nook

struct RecordedSourceTranscriptionTests {
    @Test(arguments: ["absent", "title", "duplicate", "conflicting", "future", "unknown"])
    func onlyOneExactVersionedCaptureMarkerCanIdentifyASource(kind: String) async throws {
        var metadata: [AVMetadataItem] = []
        let microphone = RecordedAudioSource.metadata(for: .microphone)
        switch kind {
        case "title":
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierTitle
            item.value = "nook:audio-source:v1:microphone" as NSString
            metadata = [item]
        case "duplicate": metadata = [microphone, microphone]
        case "conflicting": metadata = [microphone, RecordedAudioSource.metadata(for: .system)]
        case "future", "unknown":
            let item = AVMutableMetadataItem()
            item.identifier = .quickTimeMetadataInformation
            item.value = (kind == "future" ? "nook:audio-source:v2:microphone" : "nook:audio-source:v1:person") as NSString
            metadata = [item]
        default: break
        }
        #expect(try await RecordedAudioSource.source(in: metadata) == .mixed)
    }

    @Test(arguments: [TranscriptSegment.Source.microphone, .system, .mixed])
    func exactMarkersRoundTripWithoutSpeakerInference(source: TranscriptSegment.Source) async throws {
        #expect(try await RecordedAudioSource.source(in: [RecordedAudioSource.metadata(for: source)]) == source)
    }

    @Test
    func reorderedTracksAndUnlabelledPartsKeepAllWordsSourcesAndOffsets() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await capture(in: root, tracks: [
            Track(440, source: .microphone, duration: 1.2), Track(880, source: .system, start: 0.25)
        ])
        let second = try await capture(in: root, tracks: [
            Track(1_320, source: .system), Track(1_760), Track(2_200, source: .microphone)
        ])
        let third = try await capture(in: root, tracks: [Track(2_640)])
        let urls = [first, second, third]
        let bytes = try urls.map { try Data(contentsOf: $0) }
        let calls = Mutex<[URL]>([])
        let result = try await RecordedSourceTranscription.transcribeIfLabelled(
            recordingURLs: urls, localeIdentifier: "en_US", operation: { url, locale in
                #expect(locale == "en_US")
                calls.withLock { $0.append(url) }
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
                let directoryAttributes = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
                #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
                let tone = try Self.tone(url)
                return [TranscriptSegment(startTime: tone.onset + 0.05, duration: 0.1,
                                          text: tone.name, source: .microphone)]
            }
        )
        let transcript = try #require(result)
        #expect(transcript.map(\.text) == ["440", "880", "1320", "1760", "2200", "2640"])
        #expect(transcript.map(\.source) == [.microphone, .system, .system, .mixed, .microphone, .mixed])
        #expect(abs(transcript[1].startTime - 0.3) < 0.005)
        let firstDuration = try await AVURLAsset(url: first).load(.duration).seconds
        let secondDuration = try await AVURLAsset(url: second).load(.duration).seconds
        #expect(abs(transcript[2].startTime - firstDuration - 0.05) < 0.005)
        #expect(abs(transcript[5].startTime - firstDuration - secondDuration - 0.05) < 0.005)
        #expect(try urls.map { try Data(contentsOf: $0) } == bytes)
        #expect(calls.withLock { $0.count } == 6)
        for url in calls.withLock({ $0 }) {
            #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        }
    }

    @Test
    func legacyAudioUsesTheExistingMixedFileExactlyOnce() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = try await capture(in: root, tracks: [Track(440), Track(880)])
        let playback = root.appendingPathComponent("playback.m4a")
        let calls = Mutex<[URL]>([])
        let service = TranscriptionService(operation: { url, _ in
            calls.withLock { $0.append(url) }
            return [TranscriptSegment(startTime: 0, duration: 0.1, text: "Unattributed words")]
        }, timeout: 10)
        let result = try await service.transcribe(audioURL: playback, recordingURLs: [legacy], localeIdentifier: "en_US")
        #expect(calls.withLock { $0 } == [playback])
        #expect(result.map(\.source) == [.mixed])
    }

    @Test(arguments: ["capture", "playback"])
    func legacyFallbackAlsoRejectsFilesChangedDuringRecognition(changed: String) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = try await capture(in: root, tracks: [Track(440)])
        let playback = root.appendingPathComponent("playback.m4a")
        try Data("Synthetic playback".utf8).write(to: playback)
        let target = changed == "capture" ? capture : playback
        let replacement = Data("External edit".utf8)
        let service = TranscriptionService(operation: { _, _ in
            try replacement.write(to: target, options: .atomic)
            return [TranscriptSegment(startTime: 0, duration: 0.1, text: "Stale words")]
        }, timeout: 10)
        await #expect(throws: (any Error).self) {
            try await service.transcribe(audioURL: playback, recordingURLs: [capture], localeIdentifier: "en_US")
        }
        #expect(try Data(contentsOf: target) == replacement)
    }

    @Test
    func aLabelledFileIsTranscribedInsteadOfItsMixedPlaybackExport() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = try await capture(in: root, tracks: [Track(440, source: .system)])
        let playback = root.appendingPathComponent("playback.m4a")
        let service = TranscriptionService(operation: { url, _ in
            #expect(url != playback)
            return [TranscriptSegment(startTime: 0, duration: 0.1, text: "Meeting words", source: .microphone)]
        }, timeout: 10)
        let result = try await service.transcribe(audioURL: playback, recordingURLs: [capture], localeIdentifier: "en_US")
        #expect(result.map(\.source) == [.system])
    }

    @Test(arguments: ["speech failure", "changed input", "invalid result", "cancelled"])
    func aFailedOrChangedTrackCannotReturnAPartialTranscript(kind: String) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = try await capture(in: root, tracks: [Track(440, source: .microphone), Track(880, source: .system)])
        let original = try Data(contentsOf: capture)
        let calls = Mutex<[URL]>([])
        let task = Task {
            try await RecordedSourceTranscription.transcribeIfLabelled(
                recordingURLs: [capture], localeIdentifier: "en_US", operation: { url, _ in
                    let count = calls.withLock { $0.append(url); return $0.count }
                    if count == 2 {
                        switch kind {
                        case "speech failure": throw TranscriptionError.assetsUnavailable
                        case "changed input": try Data("External replacement".utf8).write(to: capture, options: .atomic)
                        case "invalid result": return [TranscriptSegment(startTime: .nan, duration: 1, text: "Invalid")]
                        default: try await Task.sleep(for: .seconds(30))
                        }
                    }
                    return [TranscriptSegment(startTime: 0, duration: 0.1, text: "Retain original recording")]
                }
            )
        }
        if kind == "cancelled" {
            for _ in 0..<1_000 {
                if calls.withLock({ $0.count }) == 2 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(calls.withLock { $0.count } == 2)
            task.cancel()
        }
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(calls.withLock { $0.count } == 2)
        for url in calls.withLock({ $0 }) {
            #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        }
        #expect(try Data(contentsOf: capture) == (kind == "changed input" ? Data("External replacement".utf8) : original))
    }

    @Test
    func identicalWordsOnDifferentSourcesAreNotSilentlyDeduplicated() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = try await capture(in: root, tracks: [Track(440, source: .system), Track(880, source: .microphone)])
        let result = try await RecordedSourceTranscription.transcribeIfLabelled(
            recordingURLs: [capture], localeIdentifier: "en_US", operation: { _, _ in
                [TranscriptSegment(startTime: 0, duration: 0.1, text: "Yes.")]
            }
        )
        #expect(result?.map(\.text) == ["Yes.", "Yes."])
        #expect(result?.map(\.source) == [.system, .microphone])
    }

    @MainActor @Test
    func recoveryPersistsCapturedSourcesInPortableMarkdownBeforeCleaningAudio() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MarkdownStore(noteLoader: { _, _ in .success((notes: [], issues: [])) })
        store.storageURL = root
        let fixture = try await capture(in: root, tracks: [Track(440, source: .system), Track(880, source: .microphone), Track(1_320)])
        let id = UUID()
        let original = store.recordingsDirectory().appendingPathComponent("\(id.uuidString).mp4")
        try FileManager.default.moveItem(at: fixture, to: original)
        let transcriber = TranscriptionService(operation: { url, _ in
            [TranscriptSegment(startTime: 0.05, duration: 0.1, text: "Synthetic tone \(try Self.tone(url).name).")]
        }, timeout: 10)
        let recovery = RecordingRecovery(store: store, transcriber: transcriber, summarizeTranscript: { transcript, title in
            SummaryService.fallbackInsights(transcript: transcript, fallbackTitle: title)
        })
        recovery.scan()
        let orphan = try #require(recovery.orphans.first { $0.id == id })
        recovery.recover(orphan, localeIdentifier: "en_US")
        let work = try #require(recovery.recoveryTaskForTesting)
        await work.value
        let saved = try #require(store.uniqueNote(id: id), Comment(rawValue: recovery.message ?? "No note saved"))
        await store.summarySessions.session(for: saved).waitForCompletion()
        let file = try #require(saved.fileURL)
        let raw = try String(contentsOf: file, encoding: .utf8)
        let decoded = try #require(MarkdownCodec.decode(raw, fileURL: file))
        #expect(decoded.transcript.map(\.source) == [.system, .microphone, .mixed])
        #expect(decoded.transcript.map(\.text) == ["Synthetic tone 440.", "Synthetic tone 880.", "Synthetic tone 1320."])
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(recovery.orphans.isEmpty)
        recovery.recover(orphan, localeIdentifier: "en_US")
        #expect(recovery.recoveryTaskForTesting == nil)
        #expect(store.notes.filter { $0.id == id }.count == 1)
        #expect(try String(contentsOf: file, encoding: .utf8) == raw)
    }

    @Test
    func sourceAudioLeftAfterFailedCleanupIsReportedInsteadOfHidden() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = try await capture(in: root, tracks: [Track(440, source: .system)])
        let retained = Mutex<URL?>(nil)
        do {
            _ = try await RecordedSourceTranscription.transcribeIfLabelled(
                recordingURLs: [capture], localeIdentifier: "en_US", operation: { url, _ in
                    retained.withLock { $0 = url }
                    throw TranscriptionError.assetsUnavailable
                }, cleanup: { _ in throw CocoaError(.fileWriteNoPermission) }
            )
            Issue.record("A failed cleanup must be visible")
        } catch AudioExtractionError.cleanupFailed(let directory) {
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = try #require(retained.withLock { $0 })
            #expect(url.deletingLastPathComponent() == directory)
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        #expect(FileManager.default.fileExists(atPath: capture.path))
    }

    private struct Track {
        let frequency: Double
        let source: TranscriptSegment.Source?
        let start: Double
        let duration: Double
        init(_ frequency: Double, source: TranscriptSegment.Source? = nil, start: Double = 0, duration: Double = 0.6) {
            self.frequency = frequency; self.source = source; self.start = start; self.duration = duration
        }
    }

    /// Use a real muxer: a metadata parser test alone cannot establish that
    /// track markers survive a file, or that isolated audio contains the right sound.
    private func capture(in root: URL, tracks: [Track]) async throws -> URL {
        let destination = root.appendingPathComponent(UUID().uuidString + ".mov")
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        var readers: [AVAssetReader] = []
        var outputs: [AVAssetReaderTrackOutput] = []
        var inputs: [AVAssetWriterInput] = []
        var assets: [AVURLAsset] = []
        defer { withExtendedLifetime(assets) {} }
        for track in tracks {
            let source = root.appendingPathComponent(UUID().uuidString + ".caf")
            try writeTone(track, to: source)
            let asset = AVURLAsset(url: source)
            assets.append(asset)
            let assetTrack = try #require(try await asset.loadTracks(withMediaType: .audio).first)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: assetTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
            ])
            reader.add(output)
            readers.append(reader); outputs.append(output)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000
            ])
            if let source = track.source { input.metadata = [RecordedAudioSource.metadata(for: source)] }
            try #require(writer.canAdd(input))
            writer.add(input); inputs.append(input)
        }
        try #require(writer.startWriting())
        defer { if writer.status == .writing { writer.cancelWriting() } }
        writer.startSession(atSourceTime: .zero)
        for index in tracks.indices {
            try #require(readers[index].startReading())
            while let buffer = outputs[index].copyNextSampleBuffer() {
                var count = 0
                try #require(CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr)
                var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
                try #require(CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count) == noErr)
                for n in timings.indices {
                    timings[n].presentationTimeStamp = timings[n].presentationTimeStamp + CMTime(seconds: tracks[index].start, preferredTimescale: 48_000)
                }
                var shifted: CMSampleBuffer?
                try #require(CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: buffer,
                    sampleTimingEntryCount: count, sampleTimingArray: &timings, sampleBufferOut: &shifted) == noErr)
                for _ in 0..<2_000 {
                    if inputs[index].isReadyForMoreMediaData || writer.status != .writing { break }
                    try await Task.sleep(for: .milliseconds(1))
                }
                try #require(inputs[index].isReadyForMoreMediaData)
                try #require(inputs[index].append(try #require(shifted)))
            }
            try #require(readers[index].status == .completed)
            inputs[index].markAsFinished()
        }
        await writer.finishWriting()
        try #require(writer.status == .completed)
        let asset = AVURLAsset(url: destination)
        let savedTracks = try await asset.loadTracks(withMediaType: .audio)
        try #require(savedTracks.count == tracks.count)
        for (index, track) in savedTracks.enumerated() {
            let metadata = try await track.load(.metadata)
            try #require(try await RecordedAudioSource.source(in: metadata) == (tracks[index].source ?? .mixed))
        }
        return destination
    }

    private func writeTone(_ track: Track, to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(track.duration * 48_000)))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData)[0]
        for n in 0..<Int(buffer.frameLength) { samples[n] = Float(0.4 * sin(2 * .pi * track.frequency * Double(n) / 48_000)) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private static func tone(_ url: URL) throws -> (name: String, onset: Double) {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData)[0]
        // A MOV edit can represent the offset as leading silence inside a
        // zero-start timeRange. The injected recognizer must report the sound's
        // time in the actual isolated file, just as Speech would.
        let onset = try #require((0..<Int(buffer.frameLength)).first { abs(samples[$0]) > 0.05 })
        let lower = onset + 4_800, upper = min(onset + 19_200, Int(buffer.frameLength))
        try #require(upper > lower)
        let values = [440, 880, 1_320, 1_760, 2_200, 2_640].map { frequency in
            var real = 0.0, imaginary = 0.0
            for n in lower..<upper {
                let phase = 2 * Double.pi * Double(frequency) * Double(n) / file.processingFormat.sampleRate
                real += Double(samples[n]) * cos(phase); imaginary += Double(samples[n]) * sin(phase)
            }
            return (frequency, 2 * hypot(real, imaginary) / Double(upper - lower))
        }
        let strongest = try #require(values.max { $0.1 < $1.1 })
        #expect(strongest.1 > 0.3)
        #expect(values.filter { $0.1 > 0.04 }.count == 1)
        return (String(strongest.0), Double(onset) / file.processingFormat.sampleRate)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NookSourceTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
