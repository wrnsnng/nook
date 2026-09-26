import AVFoundation
import Foundation
import Testing
@testable import Nook

struct SourceAudioRecordingTests {
    @Test(arguments: [false, true])
    func typedCallbacksProduceSeparateTaggedAudioAndKeepThePrimary(interleaved: Bool) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try primary(in: root)
        let before = try Data(contentsOf: original)
        let writer = try SourceAudioRecording(captureURL: original)
        writer.append(try sample(440, start: 100.1, interleaved: interleaved), source: .microphone)
        writer.append(try sample(880, start: 100, channels: 2, interleaved: interleaved), source: .system)
        #expect(SourceAudioFiles.completedAudio(for: original) == nil)
        #expect(await writer.finish(at: time(101.5)), Comment(rawValue: writer.failureDescription ?? "No writer error"))
        let audio = try #require(SourceAudioFiles.completedAudio(for: original))
        let asset = AVURLAsset(url: audio)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 1.5) < 0.005)
        let result = try await RecordedSourceTranscription.transcribeIfLabelled(
            recordingURLs: [audio], localeIdentifier: "en_US", operation: { url, _ in
                let tone = try Self.readTone(url)
                return [TranscriptSegment(startTime: tone.onset, duration: 0.1, text: tone.name)]
            }
        )
        let segments = try #require(result)
        #expect(segments.map(\.text) == ["880", "440"])
        #expect(segments.map(\.source) == [.system, .microphone])
        #expect(abs(segments[1].startTime - 0.1) < 0.005)
        #expect(try Data(contentsOf: original) == before)
        let package = SourceAudioFiles.directory(for: original)
        for (url, mode) in [(package, 0o700), (audio, 0o600), (package.appendingPathComponent("complete.json"), 0o600)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == mode)
        }
        let output = root.appendingPathComponent("playback.m4a")
        try await AudioExtractor.extractAudio(from: original, to: output)
        #expect(abs(try await AVURLAsset(url: output).load(.duration).seconds - 1.5) < 0.005)
    }

    @Test(arguments: [false, true])
    func aResumedSittingCannotIncludeQueuedAudioFromItsPausedInterval(interleaved: Bool) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try primary(in: root)
        let writer = try SourceAudioRecording(captureURL: original, notBefore: time(200.5))
        // An old packet is entirely before resume; the next straddles resume.
        writer.append(try sample(880, start: 199, duration: 0.5, interleaved: interleaved), source: .system)
        writer.append(try sample(440, start: 200, duration: 1, channels: 2, interleaved: interleaved), source: .microphone)
        #expect(await writer.finish(at: time(200.9)), Comment(rawValue: writer.failureDescription ?? "No writer error"))
        let audio = try #require(SourceAudioFiles.completedAudio(for: original))
        let asset = AVURLAsset(url: audio)
        #expect(abs(try await asset.load(.duration).seconds - 0.4) < 0.005)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(tracks.count == 1)
        let metadata = try await #require(tracks.first).load(.metadata)
        #expect(try await RecordedAudioSource.source(in: metadata) == .microphone)
        let output = root.appendingPathComponent("playback.m4a")
        try await AudioExtractor.extractAudio(from: original, to: output)
        #expect(try Self.readTone(output).name == "440")
        #expect(abs(try await AVURLAsset(url: output).load(.duration).seconds - 0.4) < 0.005)
    }

    @Test(arguments: ["overflow", "cancel", "out of order", "empty", "unknown source"])
    func incompleteSourceAudioNeverReplacesThePrimary(reason: String) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try primary(in: root)
        let before = try Data(contentsOf: original)
        let writer = try SourceAudioRecording(captureURL: original, maximumPendingBytes: reason == "overflow" ? 1 : 8_388_608)
        if reason != "empty" {
            writer.append(try sample(440, start: 100), source: reason == "unknown source" ? .mixed : .microphone)
            writer.append(try sample(880, start: 100), source: .system)
        }
        if reason == "cancel" { writer.cancel() }
        if reason == "out of order" { writer.append(try sample(440, start: 99), source: .microphone) }
        #expect(await !writer.finish(at: time(101)))
        #expect(SourceAudioFiles.completedAudio(for: original) == nil)
        #expect(try SourceAudioFiles.select([original]).urls == [original])
        #expect(try Data(contentsOf: original) == before)
    }

    @Test
    func sealingAndRepeatedFinishDoNotAdmitAnotherSitting() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try primary(in: root)
        let writer = try SourceAudioRecording(captureURL: original)
        writer.append(try sample(440, start: 100), source: .microphone)
        writer.seal()
        writer.append(try sample(880, start: 300), source: .system)
        #expect(await writer.finish(at: time(101)))
        let audio = try #require(SourceAudioFiles.completedAudio(for: original))
        let bytes = try Data(contentsOf: audio)
        #expect(await writer.finish(at: time(400)))
        #expect(try Data(contentsOf: audio) == bytes)
        #expect(abs(try await AVURLAsset(url: audio).load(.duration).seconds - 1) < 0.005)
    }

    @Test(arguments: ["duration", "missing source", "wrong source", "unattributed", "empty sources", "corrupt file"])
    func finalValidationRequiresTheIntendedTimelineAndExactSources(reason: String) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try primary(in: root)
        let writer = try SourceAudioRecording(captureURL: original)
        writer.append(try sample(440, start: 100), source: .microphone)
        #expect(await writer.finish(at: time(101)))
        let audio = try #require(SourceAudioFiles.completedAudio(for: original))
        if reason == "corrupt file" { try Data("Not recorded audio".utf8).write(to: audio, options: .atomic) }
        let sources: Set<TranscriptSegment.Source> = switch reason {
        case "missing source": [.microphone, .system]
        case "wrong source": [.system]
        case "unattributed": [.mixed]
        case "empty sources": []
        default: [.microphone]
        }
        await #expect(throws: (any Error).self) {
            try await SourceAudioRecording.validateCompletedAudio(
                audio, duration: reason == "duration" ? 2 : 1,
                sources: Dictionary(uniqueKeysWithValues: sources.map { ($0, 1.0) })
            )
        }
    }

    @Test
    func oneFullLengthTrackCannotConcealAShortenedOtherSource() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try primary(in: root)
        let writer = try SourceAudioRecording(captureURL: original)
        writer.append(try sample(440, start: 100, duration: 0.2), source: .microphone)
        writer.append(try sample(880, start: 100), source: .system)
        #expect(await writer.finish(at: time(101)))
        let audio = try #require(SourceAudioFiles.completedAudio(for: original))
        try await SourceAudioRecording.validateCompletedAudio(
            audio, duration: 1, sources: [.microphone: 0.2, .system: 1]
        )
        // Overall duration and both markers match. Still reject when the
        // microphone was expected to extend further than the finished track.
        await #expect(throws: (any Error).self) {
            try await SourceAudioRecording.validateCompletedAudio(
                audio, duration: 1, sources: [.microphone: 0.8, .system: 1]
            )
        }
    }

    @Test(arguments: ["reject", "replace", "cancel", "cleanup"])
    func delayedValidationCannotPublishAnInvalidOrCancelledCompanion(reason: String) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try primary(in: root)
        let before = try Data(contentsOf: original)
        let entered = AsyncStream<Void>.makeStream()
        let resume = AsyncStream<Void>.makeStream()
        defer { entered.continuation.finish(); resume.continuation.finish() }
        let writer = try SourceAudioRecording(captureURL: original, validateFinishedAudio: { audio, duration, sources in
            try await SourceAudioRecording.validateCompletedAudio(audio, duration: duration, sources: sources)
            entered.continuation.yield(())
            for await _ in resume.stream { break }
            if reason == "reject" { throw AudioExtractionError.invalidExport }
        })
        writer.append(try sample(440, start: 100), source: .microphone)
        let finishing = Task { await writer.finish(at: time(101)) }
        let started = await withDeadline(seconds: 5) {
            for await _ in entered.stream { return true }
            return false
        }
        guard started == true else {
            resume.continuation.finish()
            writer.cancel()
            _ = await finishing.value
            Issue.record("The completed audio never reached validation.")
            return
        }
        let package = SourceAudioFiles.directory(for: original)
        let audio = SourceAudioFiles.audio(in: package)
        let receipt = package.appendingPathComponent("complete.json")
        #expect(!FileManager.default.fileExists(atPath: receipt.path))
        #expect(try SourceAudioFiles.select([original]).urls == [original])
        if reason == "replace" { try Data("External replacement".utf8).write(to: audio, options: .atomic) }
        if reason == "cancel" || reason == "cleanup" { writer.cancel() }
        if reason == "cleanup" { try FileManager.default.removeItem(at: package) }
        resume.continuation.finish()
        #expect(await !finishing.value)
        #expect(SourceAudioFiles.completedAudio(for: original) == nil)
        #expect(!FileManager.default.fileExists(atPath: receipt.path))
        #expect(try Data(contentsOf: original) == before)
        if reason == "cleanup" { #expect(!FileManager.default.fileExists(atPath: package.path)) }
        if reason == "replace" { #expect(try Data(contentsOf: audio) == Data("External replacement".utf8)) }
    }

    @Test(arguments: ["original", "companion", "receipt"])
    func aChangedFileRejectsTheCompletedCompanion(changed: String) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try primary(in: root)
        let writer = try SourceAudioRecording(captureURL: original)
        writer.append(try sample(440, start: 100), source: .microphone)
        #expect(await writer.finish(at: time(101)))
        let audio = try #require(SourceAudioFiles.completedAudio(for: original))
        let selection = try SourceAudioFiles.select([original])
        let target = changed == "original" ? original : changed == "companion" ? audio : audio.deletingLastPathComponent().appendingPathComponent("complete.json")
        let external = Data("External change".utf8)
        try external.write(to: target, options: .atomic)
        #expect(SourceAudioFiles.completedAudio(for: original) == nil)
        #expect(throws: (any Error).self) { try selection.validate() }
        #expect(try SourceAudioFiles.select([original]).urls == [original])
        #expect(try Data(contentsOf: target) == external)
    }

    @Test
    func existingCompanionsAreNeverErasedByAnotherStart() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try primary(in: root)
        let package = SourceAudioFiles.directory(for: original)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        let file = package.appendingPathComponent("audio.mov")
        let before = Data("Earlier recording".utf8)
        try before.write(to: file)
        #expect(throws: (any Error).self) { _ = try SourceAudioRecording(captureURL: original) }
        #expect(try Data(contentsOf: file) == before)
    }

    @MainActor @Test
    func aCompletedCompanionAloneCanBeRecoveredAndIsCountedAndRemoved() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MarkdownStore(noteLoader: { _, _ in .success((notes: [], issues: [])) })
        store.storageURL = root
        let original = try primary(in: store.recordingsDirectory())
        let id = try #require(UUID(uuidString: original.deletingPathExtension().lastPathComponent))
        let writer = try SourceAudioRecording(captureURL: original)
        writer.append(try sample(440, start: 100), source: .microphone)
        writer.append(try sample(880, start: 100.1), source: .system)
        #expect(await writer.finish(at: time(101.1)))
        let audio = try #require(SourceAudioFiles.completedAudio(for: original))
        try FileManager.default.removeItem(at: original)
        #expect(SourceAudioFiles.completedAudio(for: original) == audio)
        let transcriber = TranscriptionService(operation: { url, _ in
            [TranscriptSegment(startTime: 0, duration: 0.1, text: "Synthetic \(try Self.readTone(url).name).")]
        }, timeout: 10)
        let recovery = RecordingRecovery(store: store, transcriber: transcriber, summarizeTranscript: { transcript, title in
            SummaryService.fallbackInsights(transcript: transcript, fallbackTitle: title)
        })
        recovery.scan()
        let orphan = try #require(recovery.orphans.first { $0.id == id })
        #expect(orphan.captures.map(\.lastPathComponent) == [original.lastPathComponent])
        #expect(orphan.captures.map { $0.deletingLastPathComponent().resolvingSymlinksInPath() }
                == [original.deletingLastPathComponent().resolvingSymlinksInPath()])
        #expect(orphan.byteSize >= Int64(try Data(contentsOf: audio).count))
        recovery.recover(orphan, localeIdentifier: "en_US")
        await recovery.recoveryTaskForTesting?.value
        let saved = try #require(store.uniqueNote(id: id), Comment(rawValue: recovery.message ?? "No note"))
        await store.summarySessions.session(for: saved).waitForCompletion()
        let file = try #require(saved.fileURL)
        let note = try #require(MarkdownCodec.decode(try String(contentsOf: file, encoding: .utf8), fileURL: file))
        #expect(Set(note.transcript.map(\.source)) == [.system, .microphone])
        #expect(!FileManager.default.fileExists(atPath: SourceAudioFiles.directory(for: original).path))
        #expect(recovery.orphans.isEmpty)
    }

    @Test(arguments: [AVAudioChannelCount(1), 2])
    func gapsWithinASourceStaySilentInsteadOfMovingLaterWordsEarlier(channels: AVAudioChannelCount) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try primary(in: root)
        let writer = try SourceAudioRecording(captureURL: original)
        writer.append(try sample(440, start: 100, duration: 0.2, channels: channels), source: .microphone)
        writer.append(try sample(880, start: 101, duration: 0.2, channels: channels), source: .microphone)
        #expect(await writer.finish(at: time(101.3)))
        let output = root.appendingPathComponent("playback.m4a")
        try await AudioExtractor.extractAudio(from: original, to: output)
        // Mono-to-stereo conversion distributes energy across two channels:
        // 0.4 / sqrt(2) per channel, not the original mono peak of 0.4.
        let expected = channels == 1 ? 0.4 / sqrt(2) : 0.4
        for channel in 0..<2 {
            #expect(abs(try Self.amplitude(output, channel: channel, frequency: 440, from: 0.02, to: 0.15) - expected) < 0.03)
            #expect(try Self.amplitude(output, channel: channel, frequency: 880, from: 0.3, to: 0.8) < 0.01)
            #expect(abs(try Self.amplitude(output, channel: channel, frequency: 880, from: 1.02, to: 1.15) - expected) < 0.03)
        }
        #expect(abs(try await AVURLAsset(url: output).load(.duration).seconds - 1.3) < 0.005)
    }

    @Test(arguments: [AVAudioChannelCount(1), 2])
    func resumedSourcePartsShareOnePlaybackAndTranscriptionTimeline(channels: AVAudioChannelCount) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try primary(in: root)
        let second = first.deletingPathExtension().appendingPathExtension("part-2.mp4")
        try Data("Second primary capture".utf8).write(to: second)
        let firstWriter = try SourceAudioRecording(captureURL: first)
        firstWriter.append(try sample(440, start: 100, channels: channels), source: .microphone)
        #expect(await firstWriter.finish(at: time(101.5)))
        let secondWriter = try SourceAudioRecording(captureURL: second)
        secondWriter.append(try sample(880, start: 200, duration: 0.5, channels: channels), source: .system)
        #expect(await secondWriter.finish(at: time(200.5)))
        let output = root.appendingPathComponent("playback.m4a")
        try await AudioExtractor.extractAudio(from: [first, second], to: output)
        #expect(abs(try await AVURLAsset(url: output).load(.duration).seconds - 2) < 0.005)
        let expected = channels == 1 ? 0.4 / sqrt(2) : 0.4
        for channel in 0..<2 {
            #expect(try Self.amplitude(output, channel: channel, frequency: 880, from: 1.1, to: 1.4) < 0.01)
            #expect(abs(try Self.amplitude(output, channel: channel, frequency: 880, from: 1.6, to: 1.9) - expected) < 0.03)
        }
        let transcriber = TranscriptionService(operation: { url, _ in
            [TranscriptSegment(startTime: 0, duration: 0.1, text: try Self.readTone(url).name)]
        }, timeout: 10)
        let result = try await transcriber.transcribe(audioURL: output, recordingURLs: [first, second], localeIdentifier: "en_US")
        #expect(result.map(\.text) == ["440", "880"])
        #expect(result.map(\.source) == [.microphone, .system])
        #expect(abs(result[1].startTime - 1.5) < 0.005)
        let orphan = OrphanedRecording(id: UUID(), urls: [second, SourceAudioFiles.directory(for: first), first,
                                                       SourceAudioFiles.directory(for: second)], recordedAt: .now, byteSize: 0)
        #expect(orphan.captures.map(\.lastPathComponent) == [first.lastPathComponent, second.lastPathComponent])
    }

    @MainActor @Test(arguments: [false, true])
    func recoveryRefreshesCachedPlaybackBeforeRemovingItsSourceCompanions(exportFails: Bool) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MarkdownStore(noteLoader: { _, _ in .success((notes: [], issues: [])) })
        store.storageURL = root
        let original = try primary(in: store.recordingsDirectory())
        let id = try #require(UUID(uuidString: original.deletingPathExtension().lastPathComponent))
        let first = try SourceAudioRecording(captureURL: original)
        first.append(try sample(440, start: 100), source: .microphone)
        #expect(await first.finish(at: time(101)))
        let cached = original.deletingPathExtension().appendingPathExtension("m4a")
        try await AudioExtractor.extractAudio(from: original, to: cached)
        let cachedBytes = try Data(contentsOf: cached)

        let resumed = original.deletingPathExtension().appendingPathExtension("part-2.mp4")
        try Data("Second primary".utf8).write(to: resumed)
        let second = try SourceAudioRecording(captureURL: resumed)
        second.append(try sample(880, start: 200, duration: 0.5), source: .system)
        #expect(await second.finish(at: time(200.5)))
        var extractions = 0
        let transcriber = TranscriptionService(operation: { url, _ in
            [TranscriptSegment(startTime: 0, duration: 0.1, text: try Self.readTone(url).name)]
        }, timeout: 10)
        let recovery = RecordingRecovery(store: store, extractAudio: { sources, destination in
            extractions += 1
            if exportFails {
                try await AudioExtractor.extractAudio(from: sources, to: destination, export: { _, _, _ in
                    throw AudioExtractionError.invalidExport
                })
            } else {
                try await AudioExtractor.extractAudio(from: sources, to: destination)
                #expect(abs(try await AVURLAsset(url: destination).load(.duration).seconds - 1.5) < 0.005)
                #expect(try Self.amplitude(destination, channel: 0, frequency: 880, from: 1.1, to: 1.4) > 0.25)
            }
        }, transcriber: transcriber, summarizeTranscript: { transcript, title in
            SummaryService.fallbackInsights(transcript: transcript, fallbackTitle: title)
        })
        recovery.scan()
        recovery.recover(try #require(recovery.orphans.first { $0.id == id }), localeIdentifier: "en_US")
        await recovery.recoveryTaskForTesting?.value
        #expect(extractions == 1)
        if exportFails {
            #expect(store.uniqueNote(id: id) == nil)
            #expect(try Data(contentsOf: cached) == cachedBytes)
            #expect(recovery.message != nil)
            for url in [original, resumed, SourceAudioFiles.directory(for: original), SourceAudioFiles.directory(for: resumed)] {
                #expect(FileManager.default.fileExists(atPath: url.path))
            }
        } else {
            let note = try #require(store.uniqueNote(id: id))
            await store.summarySessions.session(for: note).waitForCompletion()
            #expect(note.transcript.map(\.text) == ["440", "880"])
            #expect(abs(try #require(note.transcript.last).startTime - 1) < 0.005)
            #expect(!FileManager.default.fileExists(atPath: SourceAudioFiles.directory(for: original).path))
            #expect(!FileManager.default.fileExists(atPath: SourceAudioFiles.directory(for: resumed).path))
        }
    }

    @MainActor @Test
    func deletingAnUnfinishedCompanionKeepsFailuresVisibleAndOtherRecordingsUntouched() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MarkdownStore(noteLoader: { _, _ in .success((notes: [], issues: [])) })
        store.storageURL = root
        let original = try primary(in: store.recordingsDirectory())
        let other = try primary(in: store.recordingsDirectory())
        let id = try #require(UUID(uuidString: original.deletingPathExtension().lastPathComponent))
        let package = SourceAudioFiles.directory(for: original)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        let partial = Data("Unfinished source audio".utf8)
        try partial.write(to: SourceAudioFiles.audio(in: package))
        var refusePackage = true
        let recovery = RecordingRecovery(store: store, trashItem: { url in
            if url.pathExtension == "sources", refusePackage { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        })
        recovery.scan()
        recovery.delete(try #require(recovery.orphans.first { $0.id == id }))
        let retained = try #require(recovery.orphans.first { $0.id == id })
        #expect(retained.captures.isEmpty)
        #expect(retained.byteSize == Int64(partial.count))
        #expect(recovery.message != nil)
        #expect(FileManager.default.fileExists(atPath: other.path))
        refusePackage = false
        recovery.delete(retained)
        #expect(!FileManager.default.fileExists(atPath: package.path))
        #expect(recovery.orphans.map(\.id) == [UUID(uuidString: other.deletingPathExtension().lastPathComponent)!])
    }

    private static func amplitude(_ url: URL, channel: Int, frequency: Double, from start: Double, to end: Double) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: pcm)
        try #require(channel < Int(file.processingFormat.channelCount))
        let samples = try #require(pcm.floatChannelData)[channel]
        let lower = Int(start * file.processingFormat.sampleRate)
        let upper = min(Int(end * file.processingFormat.sampleRate), Int(pcm.frameLength))
        try #require(upper > lower)
        var real = 0.0, imaginary = 0.0
        for frame in lower..<upper {
            let phase = 2 * Double.pi * frequency * Double(frame) / file.processingFormat.sampleRate
            real += Double(samples[frame]) * cos(phase); imaginary += Double(samples[frame]) * sin(phase)
        }
        return 2 * hypot(real, imaginary) / Double(upper - lower)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NookSourceWriterTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func primary(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data("Synthetic primary capture, never overwrite".utf8).write(to: url)
        return url
    }

    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 48_000) }

    private func sample(_ frequency: Double, start: Double, duration: Double = 1,
                        channels: AVAudioChannelCount = 1, interleaved: Bool = false) throws -> CMSampleBuffer {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                               channels: channels, interleaved: interleaved))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(duration * 48_000)))
        pcm.frameLength = pcm.frameCapacity
        let samples = try #require(pcm.floatChannelData)
        for frame in 0..<Int(pcm.frameLength) {
            for channel in 0..<Int(channels) {
                samples[interleaved ? 0 : channel][interleaved ? frame * Int(channels) + channel : frame]
                    = Float(0.4 * sin(2 * .pi * frequency * Double(frame) / 48_000))
            }
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: time(start), decodeTimeStamp: .invalid)
        var optional: CMSampleBuffer?
        try #require(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
            sampleCount: Int(pcm.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &optional) == noErr)
        let buffer = try #require(optional)
        try #require(CMSampleBufferSetDataBufferFromAudioBufferList(buffer, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr)
        try #require(CMSampleBufferSetDataReady(buffer) == noErr)
        return buffer
    }

    private static func readTone(_ url: URL) throws -> (name: String, onset: Double) {
        let file = try AVAudioFile(forReading: url)
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: pcm)
        let samples = try #require(pcm.floatChannelData)[0]
        let onset = try #require((0..<Int(pcm.frameLength)).first { abs(samples[$0]) > 0.05 })
        let end = min(onset + 9_600, Int(pcm.frameLength))
        let amplitudes = [440, 880].map { frequency in
            var real = 0.0, imaginary = 0.0
            for frame in onset..<end {
                let phase = 2 * Double.pi * Double(frequency) * Double(frame) / file.processingFormat.sampleRate
                real += Double(samples[frame]) * cos(phase); imaginary += Double(samples[frame]) * sin(phase)
            }
            return (frequency, hypot(real, imaginary))
        }
        return (String(try #require(amplitudes.max { $0.1 < $1.1 }).0), Double(onset) / file.processingFormat.sampleRate)
    }
}
