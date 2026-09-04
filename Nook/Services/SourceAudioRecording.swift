import AVFoundation
import Darwin
import Foundation
import Synchronization

/// An auxiliary writer, never the sole recording. All AVFoundation state is
/// confined to `queue`; `gate` orders enqueues with finish/cancel and bounds the
/// retained buffers. The unchecked conformance describes that confinement.
final class SourceAudioRecording: @unchecked Sendable {
    typealias FinishValidation = @Sendable (URL, Double, [TranscriptSegment.Source: Double]) async throws -> Void
    private let queue = DispatchQueue(label: "com.localfirst.nook.capture.source-writer", qos: .userInitiated)
    private struct Gate {
        var accepting = true
        var valid = true
        var pendingBytes = 0
        var finishTask: Task<Bool, Never>?
        var failure: String?
    }
    private let gate = Mutex(Gate())
    private let captureURL: URL
    private let writer: AVAssetWriter
    private let inputs: [TranscriptSegment.Source: AVAssetWriterInput]
    private let maximumPendingBytes: Int
    private let notBefore: CMTime
    private let validateFinishedAudio: FinishValidation
    // Queue-confined from the first enqueue onward.
    private var initial: [Packet] = []
    private var epoch: CMTime?
    private var lastEnd: [TranscriptSegment.Source: CMTime] = [:]
    private var firstStart: [TranscriptSegment.Source: CMTime] = [:]
    private var lastFormat: [TranscriptSegment.Source: CMFormatDescription] = [:]
    private var failed = false
    private var initialBytes = 0
    var failureDescription: String? { gate.withLock { $0.failure } }

    init(captureURL: URL, notBefore: CMTime = .invalid, maximumPendingBytes: Int = 8 * 1_024 * 1_024,
         validateFinishedAudio: @escaping FinishValidation = SourceAudioRecording.validateCompletedAudio) throws {
        self.captureURL = captureURL
        self.notBefore = notBefore
        self.maximumPendingBytes = maximumPendingBytes
        self.validateFinishedAudio = validateFinishedAudio
        let directory = SourceAudioFiles.directory(for: captureURL)
        // Do not reuse or erase another attempt's directory. Private parent
        // permissions apply before the framework creates its first audio byte.
        guard mkdir(directory.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let writer = try AVAssetWriter(outputURL: SourceAudioFiles.audio(in: directory), fileType: .mov)
        var inputs: [TranscriptSegment.Source: AVAssetWriterInput] = [:]
        for source in [TranscriptSegment.Source.system, .microphone] {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000
            ])
            input.expectsMediaDataInRealTime = true
            input.metadata = [RecordedAudioSource.metadata(for: source)]
            guard writer.canAdd(input) else { throw AudioExtractionError.cannotCreateExporter }
            writer.add(input)
            inputs[source] = input
        }
        self.writer = writer
        self.inputs = inputs
    }

    func append(_ buffer: CMSampleBuffer, source: TranscriptSegment.Source) {
        let packet = Packet(buffer: buffer, source: source)
        // Non-interleaved PCM legitimately has no per-sample size array, so
        // GetTotalSampleSize returns zero. Budget the retained block instead.
        let bytes = packet.byteCount
        gate.withLock { state in
            guard state.accepting else { return }
            guard source != .mixed, buffer.isValid, buffer.dataReadiness == .ready,
                  bytes > 0, bytes <= maximumPendingBytes - state.pendingBytes else {
                state.valid = false
                state.accepting = false
                state.failure = "Invalid audio buffer or writer queue capacity exceeded."
                queue.async { self.fail() }
                return
            }
            state.pendingBytes += bytes
            // Dispatch FIFO is the single ordered writer. No task per buffer,
            // no SDK work or disk I/O on ScreenCaptureKit's callback queues.
            queue.async {
                self.receive(packet)
            }
        }
    }

    func cancel() {
        gate.withLock { state in
            state.accepting = false
            state.valid = false
            queue.async { self.fail() }
        }
    }

    func seal() { gate.withLock { $0.accepting = false } }

    /// The first finish owns the boundary; repeats await that same result.
    /// Capture calls this only after detaching a paused output or confirming
    /// stream stop. Its outer deadline may abandon the wait and invalidate it.
    func finish(at boundary: CMTime) async -> Bool {
        let task = gate.withLock { state -> Task<Bool, Never> in
            if let task = state.finishTask { return task }
            state.accepting = false
            let task = Task { await self.finishOnQueue(at: boundary) }
            state.finishTask = task
            return task
        }
        return await task.value
    }

    private func finishOnQueue(at boundary: CMTime) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                self.beginIfNeeded(force: true)
                self.finalizeOnQueue(at: boundary, continuation: continuation)
            }
        }
    }

    private func finalizeOnQueue(at boundary: CMTime, continuation: CheckedContinuation<Bool, Never>) {
        guard !failed, gate.withLock({ $0.valid }), let epoch, !lastEnd.isEmpty else {
            fail()
            continuation.resume(returning: false)
            return
        }
        let audioEnd = lastEnd.values.reduce(epoch, CMTimeMaximum)
        let end = boundary.isNumeric ? boundary : audioEnd
        guard end > epoch else {
            fail(); continuation.resume(returning: false); return
        }
        if end > audioEnd, let last = lastEnd.max(by: { $0.value < $1.value }),
           let input = inputs[last.key], let format = lastFormat[last.key] {
            // The AAC writer closes timestamp gaps instead of writing empty
            // edits. Render silence in bounded chunks, including the final
            // tail, so resumed parts keep their full duration.
            do {
                try appendSilence(from: audioEnd, to: end, input: input, format: format)
            } catch { fail(); continuation.resume(returning: false); return }
        }
        for input in inputs.values { input.markAsFinished() }
        writer.endSession(atSourceTime: end)
        let expectedSourceEnds = lastEnd.filter { firstStart[$0.key].map { $0 < end } ?? false }
            .mapValues { (CMTimeMinimum($0, end) - epoch).seconds }
        let expectedDuration = (end - epoch).seconds
        // The SDK callback is explicitly Sendable and only re-enters the
        // owned queue; it inherits no main-actor isolation.
        let completed: @Sendable () -> Void = {
            self.queue.async {
                guard self.writer.status == .completed else {
                    self.gate.withLock { $0.failure = self.writer.error?.localizedDescription ?? "Source audio did not finish." }
                    continuation.resume(returning: false)
                    return
                }
                // One completion task reads only the finalized file, not the
                // queue-confined writer. Encoder success alone is not a receipt
                // for the intended duration, source tracks or unchanged bytes.
                Task {
                    let success = await self.validateAndPublish(
                        duration: expectedDuration, sources: expectedSourceEnds
                    )
                    continuation.resume(returning: success)
                }
            }
        }
        writer.finishWriting(completionHandler: completed)
    }

    private func validateAndPublish(duration: Double, sources: [TranscriptSegment.Source: Double]) async -> Bool {
        do {
            guard gate.withLock({ $0.valid }) else { return false }
            let audio = SourceAudioFiles.audio(in: SourceAudioFiles.directory(for: captureURL))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: audio.path)
            let snapshot = try NoteCombiner.AudioFileSnapshot(url: audio)
            guard snapshot.exists else { throw AudioExtractionError.invalidExport }
            try await validateFinishedAudio(audio, duration, sources)
            // Serialize publication with cancel and recheck the file after the
            // asynchronous read. A late validation cannot recreate a cancelled
            // receipt or bless a replacement file that it never inspected.
            return try gate.withLock { state in
                guard state.valid else { return false }
                try snapshot.validate()
                try SourceAudioFiles.publishCompletion(for: captureURL)
                return true
            }
        } catch {
            gate.withLock { $0.valid = false; $0.failure = error.localizedDescription }
            return false
        }
    }

    static func validateCompletedAudio(
        _ url: URL, duration expectedDuration: Double, sources expectedSourceEnds: [TranscriptSegment.Source: Double]
    ) async throws {
        let expectedSources = Set(expectedSourceEnds.keys)
        guard expectedDuration.isFinite, expectedDuration > 0, !expectedSources.isEmpty,
              !expectedSources.contains(.mixed),
              expectedSourceEnds.values.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= expectedDuration })
        else { throw AudioExtractionError.invalidExport }
        let asset = AVURLAsset(url: url)
        defer { withExtendedLifetime(asset) {} }
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard duration.isNumeric, duration.seconds.isFinite,
              abs(duration.seconds - expectedDuration) <= 0.05,
              tracks.count == expectedSources.count else { throw AudioExtractionError.invalidExport }
        var sources = Set<TranscriptSegment.Source>()
        for track in tracks {
            let range = try await track.load(.timeRange)
            let metadata = try await track.load(.metadata)
            let source = try await RecordedAudioSource.source(in: metadata)
            guard range.isValid, range.start.isNumeric, range.duration.isNumeric,
                  range.start.seconds.isFinite, range.end.seconds.isFinite,
                  range.start >= .zero, range.duration > .zero,
                  range.end.seconds <= expectedDuration + 0.05,
                  let minimumEnd = expectedSourceEnds[source],
                  range.end.seconds + 0.05 >= minimumEnd,
                  sources.insert(source).inserted else {
                throw AudioExtractionError.invalidExport
            }
        }
        guard sources == expectedSources else { throw AudioExtractionError.invalidExport }
    }

    private static func silentPCMChunk(from start: CMTime, to end: CMTime,
                                       description: CMFormatDescription) throws -> CMSampleBuffer {
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard format.sampleRate > 0, format.sampleRate < Double(Int32.max),
              format.sampleRate.rounded() == format.sampleRate,
              let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                        frameCapacity: AVAudioFrameCount(max(1, ((end - start).seconds * format.sampleRate).rounded())))
        else { throw AudioExtractionError.invalidTimeline }
        pcm.frameLength = pcm.frameCapacity
        for buffer in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList) {
            guard let data = buffer.mData else { throw AudioExtractionError.invalidTimeline }
            memset(data, 0, Int(buffer.mDataByteSize))
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
                                       presentationTimeStamp: start, decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
            sampleCount: Int(pcm.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result) == noErr, let result,
              CMSampleBufferSetDataBufferFromAudioBufferList(result, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr,
              CMSampleBufferSetDataReady(result) == noErr else { throw AudioExtractionError.invalidTimeline }
        return result
    }

    private func receive(_ incoming: Packet) {
        guard !failed else { release(incoming.byteCount); return }
        var packet = incoming
        guard packet.start.isNumeric, packet.start.seconds.isFinite,
              packet.duration.isNumeric, packet.duration > .zero else {
            release(incoming.byteCount); fail("Source audio has invalid PCM timing."); return
        }
        if notBefore.isNumeric, packet.start < notBefore {
            // A callback queued while paused can arrive just after resume.
            // Keep only PCM frames captured after this sitting's boundary.
            guard packet.start + packet.duration > notBefore else { release(incoming.byteCount); return }
            let frames = CMSampleBufferGetNumSamples(packet.buffer)
            let skipped = Int(ceil((notBefore - packet.start).seconds / packet.duration.seconds * Double(frames)))
            guard skipped < frames else { release(incoming.byteCount); return }
            guard let trimmed = Self.trimmingPCM(packet.buffer, skipping: skipped) else {
                release(incoming.byteCount); fail("Source audio PCM trim failed."); return
            }
            packet = Packet(buffer: trimmed, source: packet.source)
            release(incoming.byteCount - packet.byteCount)
        }
        if epoch == nil {
            initialBytes += packet.byteCount
            guard initial.count < 128, initialBytes <= maximumPendingBytes else { fail(); return }
            initial.append(packet)
            beginIfNeeded(force: false)
        } else { write(packet) }
    }

    private func beginIfNeeded(force: Bool) {
        guard epoch == nil, !failed, !initial.isEmpty else { return }
        let first = initial.map(\.start).reduce(initial[0].start, CMTimeMinimum)
        let last = initial.map(\.start).reduce(first, CMTimeMaximum)
        // The two callback queues can deliver their first packets in either
        // order. A short bounded preroll establishes a shared clock without
        // assigning an arbitrary first track the recording's zero point.
        guard force || Set(initial.map(\.source)).count == 2 || (last - first).seconds >= 0.25 else { return }
        guard writer.startWriting() else { fail(); return }
        writer.startSession(atSourceTime: first)
        epoch = first
        let packets = initial.sorted { $0.start < $1.start }
        initial.removeAll()
        initialBytes = 0
        for packet in packets { write(packet) }
    }

    private func write(_ packet: Packet) {
        defer { release(packet.byteCount) }
        guard !failed else { return }
        guard let epoch, let input = inputs[packet.source], packet.start >= epoch,
              lastEnd[packet.source].map({ packet.start >= $0 - CMTime(value: 1, timescale: 48_000) }) ?? true
        else { fail("Source audio timestamps are not ordered."); return }
        if let end = lastEnd[packet.source], packet.start > end, let format = lastFormat[packet.source] {
            do { try appendSilence(from: end, to: packet.start, input: input, format: format) }
            catch { fail(); return }
        }
        guard waitUntilReady(input) else { fail("Source audio encoder could not keep up."); return }
        guard input.append(packet.buffer) else { fail(writer.error?.localizedDescription ?? "Source audio append failed."); return }
        if firstStart[packet.source] == nil { firstStart[packet.source] = packet.start }
        lastEnd[packet.source] = packet.start + packet.duration
        lastFormat[packet.source] = packet.buffer.formatDescription
    }

    private func appendSilence(from start: CMTime, to end: CMTime,
                               input: AVAssetWriterInput, format: CMFormatDescription) throws {
        let rate = AVAudioFormat(cmAudioFormatDescription: format).sampleRate
        let frames = ((end - start).seconds * rate).rounded()
        guard rate.isFinite, rate > 0, rate < Double(Int32.max), rate.rounded() == rate,
              frames.isFinite, frames >= 0, frames < Double(Int64.max) else { throw AudioExtractionError.invalidTimeline }
        var remaining = Int64(frames)
        var cursor = start
        while remaining > 0 {
            guard waitUntilReady(input) else { throw AudioExtractionError.cannotCreateExporter }
            let count = min(remaining, 4_800)
            let next = cursor + CMTime(value: count, timescale: CMTimeScale(rate))
            let silence = try Self.silentPCMChunk(from: cursor, to: next, description: format)
            guard input.append(silence) else { throw AudioExtractionError.invalidExport }
            remaining -= count
            cursor = next
        }
    }

    private func waitUntilReady(_ input: AVAssetWriterInput) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + 250_000_000
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing, gate.withLock({ $0.valid }),
                  DispatchTime.now().uptimeNanoseconds < deadline else { return false }
            // Only this auxiliary file writer waits. Capture callbacks never
            // wait for it, and cancellation is checked every millisecond.
            Thread.sleep(forTimeInterval: 0.001)
        }
        return gate.withLock { $0.valid }
    }

    private func fail(_ reason: String? = nil) {
        failed = true
        initial.removeAll()
        release(initialBytes)
        initialBytes = 0
        gate.withLock {
            $0.valid = false
            $0.accepting = false
            if $0.failure == nil { $0.failure = reason ?? writer.error?.localizedDescription ?? "Source audio could not be written." }
        }
        if writer.status == .writing { writer.cancelWriting() }
    }

    private func release(_ bytes: Int) { gate.withLock { $0.pendingBytes -= bytes } }

    /// CoreMedia's range-copy API rejects non-interleaved audio, which is a
    /// normal microphone format. Copy each buffer's selected PCM frames instead.
    /// The new sample owns that copy, not pointers into the capture callback.
    static func trimmingPCM(_ buffer: CMSampleBuffer, skipping frames: Int) -> CMSampleBuffer? {
        guard let format = buffer.formatDescription,
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format),
              description.pointee.mFormatID == kAudioFormatLinearPCM,
              description.pointee.mSampleRate > 0,
              description.pointee.mSampleRate < Double(Int32.max),
              description.pointee.mSampleRate.rounded() == description.pointee.mSampleRate else { return nil }
        let count = CMSampleBufferGetNumSamples(buffer) - frames
        let stride = Int(description.pointee.mBytesPerFrame)
        guard frames >= 0, count > 0, stride > 0 else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(description.pointee.mSampleRate)),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(buffer)
                + CMTime(value: Int64(frames), timescale: CMTimeScale(description.pointee.mSampleRate)),
            decodeTimeStamp: .invalid
        )
        var result: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format, sampleCount: count,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
            sampleSizeArray: nil, sampleBufferOut: &result) == noErr, let result else { return nil }
        do {
            try buffer.withAudioBufferList { source, _ in
                let selected = AudioBufferList.allocate(maximumBuffers: source.count)
                defer { selected.unsafeMutablePointer.deallocate() }
                for index in source.indices {
                    guard let data = source[index].mData,
                          (frames + count) * stride <= Int(source[index].mDataByteSize) else {
                        throw AudioExtractionError.invalidTimeline
                    }
                    selected[index] = AudioBuffer(mNumberChannels: source[index].mNumberChannels,
                                                  mDataByteSize: UInt32(count * stride),
                                                  mData: data.advanced(by: frames * stride))
                }
                guard CMSampleBufferSetDataBufferFromAudioBufferList(result,
                    blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
                    flags: 0, bufferList: selected.unsafePointer) == noErr else {
                    throw AudioExtractionError.invalidTimeline
                }
            }
            guard CMSampleBufferSetDataReady(result) == noErr else { return nil }
            return result
        } catch { return nil }
    }

    /// The retained CMSampleBuffer and its data are immutable. Only the writer
    /// queue reads them after the callback; no pointer outlives this owner.
    private struct Packet: @unchecked Sendable {
        let buffer: CMSampleBuffer
        let source: TranscriptSegment.Source
        var byteCount: Int { buffer.dataBuffer.map(CMBlockBufferGetDataLength) ?? 0 }
        var start: CMTime { CMSampleBufferGetPresentationTimeStamp(buffer) }
        var duration: CMTime {
            guard let format = buffer.formatDescription,
                  let description = CMAudioFormatDescriptionGetStreamBasicDescription(format),
                  description.pointee.mFormatID == kAudioFormatLinearPCM,
                  description.pointee.mSampleRate.isFinite, description.pointee.mSampleRate > 0 else { return .invalid }
            return CMTime(seconds: Double(CMSampleBufferGetNumSamples(buffer)) / description.pointee.mSampleRate,
                          preferredTimescale: 1_000_000_000)
        }
    }
}
