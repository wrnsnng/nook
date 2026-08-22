import AVFoundation
import AudioToolbox
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Synchronization

@MainActor
final class CaptureService: NSObject, SCStreamDelegate, SCRecordingOutputDelegate, SCStreamOutput {
    private var stream: SCStream?
    private var streamID: ObjectIdentifier?
    /// Called when the capture stream ends without Nook asking it to, so a
    /// meeting cannot quietly stop recording while it still looks live.
    var onUnexpectedStop: (@MainActor (any Error) -> Void)?
    /// Set while Nook is deliberately winding the stream down, which is the
    /// only way to tell a requested stop from one the system imposed.
    private var isStopping = false
    /// The asynchronous `stopCapture()` operation is kept alive and owned until
    /// it actually returns. A timeout may stop the UI waiting, but it must not
    /// make a still-running capture look idle and allow another one to start.
    private var streamStopTask: Task<Void, Never>?
    private var stopState: CaptureStopState?
    /// A recording-output callback can precede the stream's stop callback when
    /// ScreenCaptureKit fails on its own. Carry it into the stop barrier that
    /// recovery creates on the next main-actor turn.
    private var unmatchedRecordingFinalization: Result<Void, Error>?
    private var clearWhenStreamStops = false
    private var streamEndedUnexpectedly = false

    /// Held for as long as audio is being captured. See `holdSleepAtBay`.
    private var sleepAssertion: (any NSObjectProtocol)?
    private var recordingOutput: SCRecordingOutput?
    private var recordingOutputID: ObjectIdentifier?
    private var recordingURL: URL?
    private var baseRecordingURL: URL?
    private var recordingURLs: [URL] = []
    private var nextSegmentNumber = 2
    private(set) var isPaused = false
    private let finalizationWaiter: CaptureFinalizationWaiter
    private let preparesLiveInput = Mutex(false)
    private weak var liveTranscription: LiveTranscriptionService?
    /// One ordered channel for live speech input, drained by a single task.
    private var liveIngestPump: Task<Void, Never>?
    private let liveIngestPipe = Mutex<AsyncStream<LiveIngest>.Continuation?>(nil)
    private var audioLevelHandler: ((Double, TranscriptSegment.Source) -> Void)?
    private let systemAudioQueue = DispatchQueue(
        label: "com.localfirst.nook.capture.system-audio",
        qos: .userInteractive
    )
    private let microphoneQueue = DispatchQueue(
        label: "com.localfirst.nook.capture.microphone",
        qos: .userInteractive
    )
    private(set) var lastError: Error?

    override convenience init() {
        // Finalizing writes the index for everything recorded so far, so a
        // long meeting legitimately takes longer than a short one. Twelve
        // seconds was enough for a quick test and not for a real meeting, and
        // running out meant losing the recording. Waiting costs a moment;
        // giving up costs the meeting.
        self.init(finalizationTimeout: .seconds(120))
    }

    init(finalizationTimeout: Duration) {
        self.finalizationWaiter = CaptureFinalizationWaiter(
            timeout: finalizationTimeout
        )
        super.init()
    }

    var isCapturing: Bool { stream != nil }

    func attachLiveTranscription(_ service: LiveTranscriptionService) {
        guard stream != nil else { return }
        closeLiveIngestPump()
        liveTranscription = service
        preparesLiveInput.withLock { $0 = !isPaused }

        // Buffers reach the recognizer through one ordered stream drained by
        // a single task. Spawning a `Task` per buffer instead would hand each
        // one to the main actor independently, and unstructured tasks carry no
        // ordering guarantee: the resampling converter feeding `SpeechAnalyzer`
        // is stateful, so reordered audio corrupts recognition in ways that
        // look like the recognizer simply mishearing. This is the same shape
        // `DictationAudioSource` uses for its tap.
        let pair = AsyncStream<LiveIngest>.makeStream(
            bufferingPolicy: .bufferingNewest(240)
        )
        liveIngestPipe.withLock { $0 = pair.continuation }
        liveIngestPump = Task { @MainActor [weak self] in
            for await event in pair.stream {
                self?.deliverLiveInput(event)
            }
        }
    }

    private func deliverLiveInput(_ event: LiveIngest) {
        guard let liveTranscription else { return }
        liveTranscription.ingest(event.buffer, source: event.source)
    }

    /// Ends the ingest stream and abandons anything still queued in it.
    private func closeLiveIngestPump() {
        liveIngestPipe.withLock {
            $0?.finish()
            $0 = nil
        }
        liveIngestPump?.cancel()
        liveIngestPump = nil
    }

    func requestPermissions() async throws {
        if !CGPreflightScreenCaptureAccess() {
            guard CGRequestScreenCaptureAccess() else {
                throw CaptureError.screenRecordingPermissionDenied
            }
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw CaptureError.microphonePermissionDenied
            }
        case .denied, .restricted:
            throw CaptureError.microphonePermissionDenied
        @unknown default:
            throw CaptureError.microphonePermissionDenied
        }
    }

    func start(
        to url: URL,
        permissionsAreReady: Bool = false,
        onAudioLevel: ((Double, TranscriptSegment.Source) -> Void)? = nil
    ) async throws {
        guard stream == nil, streamStopTask == nil else {
            throw CaptureError.alreadyRecording
        }
        if !permissionsAreReady {
            try await requestPermissions()
        }
        preparesLiveInput.withLock { $0 = false }

        let availableContent = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        guard let display = availableContent.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let outputConfiguration = SCRecordingOutputConfiguration()
        outputConfiguration.outputURL = url
        outputConfiguration.outputFileType = .mp4
        outputConfiguration.videoCodecType = .h264

        let recordingOutput = SCRecordingOutput(
            configuration: outputConfiguration,
            delegate: self
        )
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addRecordingOutput(recordingOutput)
        try stream.addStreamOutput(
            self,
            type: .audio,
            sampleHandlerQueue: systemAudioQueue
        )
        try stream.addStreamOutput(
            self,
            type: .microphone,
            sampleHandlerQueue: microphoneQueue
        )

        self.lastError = nil
        self.streamEndedUnexpectedly = false
        self.stopState = nil
        self.unmatchedRecordingFinalization = nil
        self.clearWhenStreamStops = false
        self.recordingURL = url
        self.baseRecordingURL = url
        self.recordingURLs = [url]
        self.nextSegmentNumber = 2
        self.recordingOutput = recordingOutput
        self.recordingOutputID = ObjectIdentifier(recordingOutput)
        self.stream = stream
        self.streamID = ObjectIdentifier(stream)
        self.isPaused = false
        self.liveTranscription = nil
        closeLiveIngestPump()
        self.audioLevelHandler = onAudioLevel

        do {
            try await stream.startCapture()
        } catch {
            clear()
            throw error
        }
        holdSleepAtBay()
        NookEventLog.write(.captureStarted)
    }

    func pause(finalizationTimeout: Duration? = nil) async throws {
        guard let stream, let recordingOutput, !isPaused else {
            throw isPaused ? CaptureError.alreadyPaused : CaptureError.notRecording
        }

        preparesLiveInput.withLock { $0 = false }
        isPaused = true
        do {
            try await finalizationWaiter.wait(
                timeout: finalizationTimeout
            ) {
                try stream.removeRecordingOutput(recordingOutput)
            }
        } catch {
            // The removal closure runs before the waiter can suspend, so a
            // timeout or cancellation here means the output was already
            // detached and no further audio reaches disk. Treating that as a
            // failed pause resurrected a meeting that looked live while
            // writing nothing for the rest of the recording, so the pause
            // stands and only the file-close receipt goes missing. Any other
            // error is the removal itself failing, which genuinely leaves
            // capture active.
            if Self.waitErrorMeansRemovalLanded(error) {
                NookEventLog.write(.capturePauseFinalizationUnconfirmed)
            } else {
                isPaused = false
                preparesLiveInput.withLock { $0 = liveTranscription != nil }
                throw error
            }
        }
        self.recordingOutput = nil
        recordingOutputID = nil
        recordingURL = nil
        releaseSleepAssertion()
    }

    /// Whether a `finalizationWaiter.wait` failure around a completed removal
    /// means the removal itself landed. The closure executes synchronously
    /// before suspension, so only its own error reports a failed removal; a
    /// deadline or task cancellation reports a missing callback instead.
    static func waitErrorMeansRemovalLanded(_ error: Error) -> Bool {
        switch error {
        case CaptureError.finalizationTimedOut, is CancellationError:
            true
        default:
            false
        }
    }

    func resume() throws {
        guard let stream, isPaused, recordingOutput == nil,
              let baseRecordingURL
        else {
            throw isPaused ? CaptureError.alreadyRecording : CaptureError.notPaused
        }

        let segmentURL = baseRecordingURL
            .deletingPathExtension()
            .appendingPathExtension("part-\(nextSegmentNumber).mp4")
        nextSegmentNumber += 1
        try? FileManager.default.removeItem(at: segmentURL)

        let configuration = SCRecordingOutputConfiguration()
        configuration.outputURL = segmentURL
        configuration.outputFileType = .mp4
        configuration.videoCodecType = .h264
        let output = SCRecordingOutput(
            configuration: configuration,
            delegate: self
        )
        try stream.addRecordingOutput(output)

        recordingURL = segmentURL
        recordingURLs.append(segmentURL)
        recordingOutput = output
        recordingOutputID = ObjectIdentifier(output)
        isPaused = false
        holdSleepAtBay()
        preparesLiveInput.withLock { $0 = liveTranscription != nil }
    }

    /// How long finalization is given when the user is quitting.
    ///
    /// Short enough that Nook does not look wedged and invite a force quit,
    /// which would kill finalization mid-write.
    static let quitFinalizationTimeout = Duration.seconds(20)

    func stop(finalizationTimeout: Duration? = nil) async throws -> [URL] {
        guard let stream, !recordingURLs.isEmpty else {
            throw CaptureError.notRecording
        }
        isStopping = true
        preparesLiveInput.withLock { $0 = false }

        let completedURLs = recordingURLs
        if streamEndedUnexpectedly {
            // The stream is already terminal, so asking ScreenCaptureKit to stop
            // it again only turns a recoverable partial recording into an error.
            // Its recording output may still be closing the file; wait for that
            // callback when one exists, then let extraction decide whether the
            // resulting file contains usable audio.
            if recordingOutput != nil {
                if let unmatchedRecordingFinalization {
                    self.unmatchedRecordingFinalization = nil
                    if case .failure(let error) = unmatchedRecordingFinalization {
                        lastError = error
                    }
                } else {
                    do {
                        try await finalizationWaiter.wait(
                            timeout: finalizationTimeout
                        ) {}
                    } catch {
                        lastError = error
                    }
                }
            }
            let existingURLs = completedURLs.filter {
                FileManager.default.fileExists(atPath: $0.path)
            }
            let terminalError = lastError
            clear()
            guard !existingURLs.isEmpty else {
                throw terminalError ?? CaptureError.recordingMissing
            }
            NookEventLog.write(.captureRecoveredAfterUnexpectedStop)
            return existingURLs
        }

        stopState = CaptureStopState(
            waitsForRecordingFinalization: !isPaused
        )
        if let unmatchedRecordingFinalization {
            stopState?.receiveRecordingFinalization(
                unmatchedRecordingFinalization
            )
            self.unmatchedRecordingFinalization = nil
        }
        if isPaused {
            do {
                try await finalizationWaiter.wait(
                    timeout: finalizationTimeout
                ) {
                    try self.beginStoppingStream(stream)
                }
            } catch {
                preserveStopOwnershipAfterFailure()
                throw error
            }
        } else {
            do {
                try await finalizationWaiter.wait(
                    timeout: finalizationTimeout
                ) {
                    try self.beginStoppingStream(stream)
                }
            } catch {
                preserveStopOwnershipAfterFailure()
                throw error
            }
        }
        clear()

        let existingURLs = completedURLs.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard !existingURLs.isEmpty else {
            throw CaptureError.recordingMissing
        }
        NookEventLog.write(.captureStopped)
        return existingURLs
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let stoppedStreamID = ObjectIdentifier(stream)
        Task { @MainActor in
            guard stoppedStreamID == self.streamID else { return }
            self.lastError = error
            if self.isStopping, self.stopState != nil {
                self.streamStopTask?.cancel()
                self.receiveStreamStop(.failure(error))
                return
            }
            self.streamEndedUnexpectedly = true
            NookEventLog.write(.captureStoppedUnexpectedly)
            // The system can tear the stream down on its own: the Mac sleeps,
            // displays are reconfigured, permission is revoked. Recording then
            // ends while the meeting still shows as running, and the user finds
            // out when the note is short. Reporting it lets the meeting be
            // finished with whatever was captured rather than lost.
            self.onUnexpectedStop?(error)
        }
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        let outputStreamID = ObjectIdentifier(stream)
        guard sampleBuffer.isValid, sampleBuffer.dataReadiness == .ready else { return }
        let source: TranscriptSegment.Source
        switch outputType {
        case .audio:
            source = .system
        case .microphone:
            source = .microphone
        default:
            return
        }

        let level = Self.normalizedAudioLevel(in: sampleBuffer)
        let liveBuffer: AVAudioPCMBuffer? = if preparesLiveInput.withLock({ $0 }),
            let buffer = Self.pcmBuffer(from: sampleBuffer) {
            buffer
        } else {
            nil
        }

        // Level smoothing downstream takes a running maximum, so delivery
        // order is irrelevant and the hop costs nothing in correctness.
        Task { @MainActor [weak self] in
            guard let self, outputStreamID == self.streamID else { return }
            self.audioLevelHandler?(level, source)
        }

        // Yield is thread-safe and order-preserving, so buffers produced by
        // this callback reach the recognizer in the order they were spoken.
        if let liveBuffer {
            liveIngestPipe.withLock { pipe in
                pipe?.yield(LiveIngest(buffer: liveBuffer, source: source))
                return ()
            }
        }
    }

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {}

    nonisolated func recordingOutput(
        _ recordingOutput: SCRecordingOutput,
        didFailWithError error: any Error
    ) {
        let outputID = ObjectIdentifier(recordingOutput)
        Task { @MainActor in
            self.receiveRecordingFinalization(
                .failure(error),
                from: outputID
            )
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        let outputID = ObjectIdentifier(recordingOutput)
        Task { @MainActor in
            self.receiveRecordingFinalization(
                .success(()),
                from: outputID
            )
        }
    }

    private func beginStoppingStream(_ stream: SCStream) throws {
        guard streamStopTask == nil else {
            throw CaptureError.finalizationInProgress
        }
        streamStopTask = Task { @MainActor [weak self] in
            do {
                try await stream.stopCapture()
                self?.receiveStreamStop(.success(()))
            } catch {
                self?.receiveStreamStop(.failure(error))
            }
        }
    }

    private func receiveStreamStop(_ result: Result<Void, Error>) {
        streamStopTask = nil
        if case .failure(let error) = result {
            lastError = error
        }
        stopState?.receiveStreamStop(result)
        resolveRequestedStopIfReady()

        if clearWhenStreamStops {
            clear()
        }
    }

    private func receiveRecordingFinalization(
        _ result: Result<Void, Error>,
        from outputID: ObjectIdentifier
    ) {
        // A timed-out output can finish after another meeting has started. Its
        // delegate must never resolve or fail the newer meeting's waiter.
        guard outputID == recordingOutputID else { return }
        if case .failure(let error) = result {
            lastError = error
        }

        if stopState != nil {
            stopState?.receiveRecordingFinalization(result)
            resolveRequestedStopIfReady()
        } else if isPaused || streamEndedUnexpectedly {
            // Pause and an unexpected stream stop can already be waiting for
            // this callback without a requested stream-stop barrier.
            if finalizationWaiter.isWaiting {
                finalizationWaiter.resolve(result)
            } else {
                unmatchedRecordingFinalization = result
            }
        } else {
            unmatchedRecordingFinalization = result
            guard case .failure(let error) = result else { return }
            preparesLiveInput.withLock { $0 = false }
            NookEventLog.write(.captureStoppedUnexpectedly)
            onUnexpectedStop?(error)
        }
    }

    private func resolveRequestedStopIfReady() {
        guard let result = stopState?.resolution else { return }
        finalizationWaiter.resolve(result)
    }

    private func preserveStopOwnershipAfterFailure() {
        streamStopTask?.cancel()
        preparesLiveInput.withLock { $0 = false }
        closeLiveIngestPump()
        liveTranscription = nil
        audioLevelHandler = nil
        releaseSleepAssertion()

        if stopState?.streamHasStopped == true || streamStopTask == nil {
            clear()
        } else {
            // `stopCapture()` has not returned. Keep `stream` and the task until
            // it does, which prevents a second capture from overlapping it.
            clearWhenStreamStops = true
        }
    }

    /// Stops the Mac dropping into idle sleep mid-meeting.
    ///
    /// A sleeping Mac tears down the ScreenCaptureKit stream, which ends the
    /// recording with no error and no note. Nothing defers idle sleep during a
    /// meeting the user is only listening to: they are not typing, so from the
    /// system's point of view the machine is unused. Default idle sleep on a
    /// laptop arrives around the twenty minute mark, which is exactly when
    /// recordings were being cut short.
    ///
    /// The display is held awake as well, which is not what an audio recorder
    /// would normally need. Nook captures sound through ScreenCaptureKit, a
    /// screen API: the two-by-two video stream exists only because capturing
    /// system audio requires a stream at all. When the display sleeps that
    /// stream stops, and the audio stops with it. Keeping the screen lit costs
    /// battery; losing the meeting costs more.
    ///
    /// Closing the lid still sleeps the machine; no application can prevent
    /// that.
    private func holdSleepAtBay() {
        guard sleepAssertion == nil else { return }
        sleepAssertion = ProcessInfo.processInfo.beginActivity(
            options: [
                .idleSystemSleepDisabled,
                .idleDisplaySleepDisabled,
                .automaticTerminationDisabled
            ],
            reason: "Recording a meeting"
        )
    }

    private func releaseSleepAssertion() {
        guard let sleepAssertion else { return }
        ProcessInfo.processInfo.endActivity(sleepAssertion)
        self.sleepAssertion = nil
    }

    private func clear() {
        releaseSleepAssertion()
        isStopping = false
        streamStopTask = nil
        stopState = nil
        unmatchedRecordingFinalization = nil
        clearWhenStreamStops = false
        streamEndedUnexpectedly = false
        stream = nil
        streamID = nil
        recordingOutput = nil
        recordingOutputID = nil
        recordingURL = nil
        baseRecordingURL = nil
        recordingURLs = []
        nextSegmentNumber = 2
        isPaused = false
        finalizationWaiter.cancel()
        closeLiveIngestPump()
        liveTranscription = nil
        audioLevelHandler = nil
        preparesLiveInput.withLock { $0 = false }
        lastError = nil
    }

    nonisolated private static func normalizedAudioLevel(
        in sampleBuffer: CMSampleBuffer
    ) -> Double {
        guard
            let description = sampleBuffer.formatDescription,
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description)
        else {
            return 0
        }
        let format = streamDescription.pointee
        var sumSquares = 0.0
        var sampleCount = 0

        do {
            try sampleBuffer.withAudioBufferList { buffers, _ in
                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    if format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                       format.mBitsPerChannel == 32 {
                        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                        let samples = data.assumingMemoryBound(to: Float.self)
                        for index in 0..<count {
                            let value = Double(samples[index])
                            sumSquares += value * value
                        }
                        sampleCount += count
                    } else if format.mBitsPerChannel == 16 {
                        let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                        let samples = data.assumingMemoryBound(to: Int16.self)
                        for index in 0..<count {
                            let value = Double(samples[index]) / Double(Int16.max)
                            sumSquares += value * value
                        }
                        sampleCount += count
                    }
                }
            }
        } catch {
            return 0
        }

        guard sampleCount > 0 else { return 0 }
        let rms = sqrt(sumSquares / Double(sampleCount))
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels + 55) / 55))
    }

    nonisolated private static func pcmBuffer(
        from sampleBuffer: CMSampleBuffer
    ) -> AVAudioPCMBuffer? {
        guard
            let description = sampleBuffer.formatDescription,
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
            let format = AVAudioFormat(streamDescription: streamDescription),
            sampleBuffer.numSamples > 0,
            let destination = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(sampleBuffer.numSamples)
            )
        else {
            return nil
        }

        destination.frameLength = AVAudioFrameCount(sampleBuffer.numSamples)
        do {
            try sampleBuffer.withAudioBufferList { sourceBuffers, _ in
                let destinationBuffers = UnsafeMutableAudioBufferListPointer(
                    destination.mutableAudioBufferList
                )
                for index in 0..<min(sourceBuffers.count, destinationBuffers.count) {
                    guard
                        let source = sourceBuffers[index].mData,
                        let target = destinationBuffers[index].mData
                    else {
                        continue
                    }
                    let byteCount = min(
                        Int(sourceBuffers[index].mDataByteSize),
                        Int(destinationBuffers[index].mDataByteSize)
                    )
                    target.copyMemory(from: source, byteCount: byteCount)
                    destinationBuffers[index].mDataByteSize = UInt32(byteCount)
                }
            }
            return destination
        } catch {
            return nil
        }
    }
}

/// `AVAudioPCMBuffer` owns the copied sample memory and is never mutated after
/// leaving the capture callback, so it is safe to hand to the main-actor speech
/// pipeline.
/// Hands one audio buffer across an isolation boundary, tagged with the track
/// it belongs to.
///
/// `AVAudioPCMBuffer` is a reference type Apple does not mark `Sendable`. Every
/// buffer wrapped here is freshly allocated by its producer and handed over
/// exactly once, so no two isolation domains ever hold the same one.
struct LiveIngest: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let source: TranscriptSegment.Source
}

enum CaptureError: LocalizedError {
    case screenRecordingPermissionDenied
    case microphonePermissionDenied
    case alreadyRecording
    case alreadyPaused
    case notPaused
    case notRecording
    case noDisplay
    case recordingMissing
    case finalizationInProgress
    case finalizationTimedOut

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionDenied:
            "Screen & System Audio Recording permission is required. Enable Nook in System Settings → Privacy & Security."
        case .microphonePermissionDenied:
            "Microphone permission is required to capture your side of the conversation."
        case .alreadyRecording:
            "A meeting is already being recorded."
        case .alreadyPaused:
            "This recording is already paused."
        case .notPaused:
            "This recording is not paused."
        case .notRecording:
            "There is no active recording."
        case .noDisplay:
            "Nook could not find a display to capture system audio from."
        case .recordingMissing:
            "The recording did not finish writing to disk."
        case .finalizationInProgress:
            "Nook is already securing this recording."
        case .finalizationTimedOut:
            "Nook took too long to finish writing this recording. The audio was kept so nothing is lost."
        }
    }
}

/// Joins the two independent events that make a requested stop complete.
///
/// `SCStream.stopCapture()` returning only proves that capture stopped. The
/// recording-output delegate separately proves that its container finished
/// writing. Resuming the caller on either event alone can expose a partial file
/// or discard ownership of a stream that is still running.
struct CaptureStopState {
    let waitsForRecordingFinalization: Bool
    private var streamResult: Result<Void, Error>?
    private var recordingResult: Result<Void, Error>?

    init(waitsForRecordingFinalization: Bool) {
        self.waitsForRecordingFinalization = waitsForRecordingFinalization
        if !waitsForRecordingFinalization {
            recordingResult = .success(())
        }
    }

    var streamHasStopped: Bool { streamResult != nil }

    var resolution: Result<Void, Error>? {
        guard let streamResult, let recordingResult else { return nil }
        do {
            try streamResult.get()
            try recordingResult.get()
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    mutating func receiveStreamStop(_ result: Result<Void, Error>) {
        guard streamResult == nil else { return }
        streamResult = result
    }

    mutating func receiveRecordingFinalization(
        _ result: Result<Void, Error>
    ) {
        guard recordingResult == nil else { return }
        recordingResult = result
    }
}

/// Waits for ScreenCaptureKit's recording-output delegate without allowing a
/// missing callback to wedge pause, stop, cancellation, or application quit.
@MainActor
final class CaptureFinalizationWaiter {
    private let timeout: Duration
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?

    init(timeout: Duration) {
        self.timeout = timeout
    }

    var isWaiting: Bool { continuation != nil }

    /// Waits for finalization, optionally for less time than usual.
    ///
    /// Quitting cannot wait as patiently as stopping can: the user has already
    /// asked the app to go away, and a menu-bar app that appears wedged invites
    /// a force quit, which kills finalization mid-write and produces the very
    /// corrupt file the wait exists to avoid.
    func wait(
        timeout override: Duration? = nil,
        start: @escaping @MainActor () throws -> Void
    ) async throws {
        // Resolved here and carried down rather than stored on the waiter. A
        // second, overlapping call would otherwise overwrite a shared property
        // before being rejected, and the first call's timer would then run to
        // somebody else's deadline. Callers currently serialise these, but that
        // is their discipline, not this class's guarantee.
        let deadline = override ?? timeout
        try Task.checkCancellation()
        try await withTaskCancellationHandler(
            operation: {
                try await self.suspendUntilResolved(
                    deadline: deadline,
                    start: start
                )
            },
            onCancel: { [weak self] in
                Task { @MainActor in
                    self?.cancel()
                }
            }
        )
    }

    private func suspendUntilResolved(
        deadline: Duration,
        start: @escaping @MainActor () throws -> Void
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            guard self.continuation == nil else {
                continuation.resume(throwing: CaptureError.finalizationInProgress)
                return
            }

            self.continuation = continuation
            timeoutTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: deadline)
                guard !Task.isCancelled else { return }
                resolve(.failure(CaptureError.finalizationTimedOut))
            }

            do {
                try start()
                if Task.isCancelled {
                    resolve(.failure(CancellationError()))
                }
            } catch {
                resolve(.failure(error))
            }
        }
    }

    func resolve(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(with: result)
    }

    func cancel() {
        guard continuation != nil else {
            timeoutTask?.cancel()
            timeoutTask = nil
            return
        }
        resolve(.failure(CancellationError()))
    }
}
