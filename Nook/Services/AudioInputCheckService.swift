import AVFoundation
import Combine
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Synchronization

/// The two audio tracks shown by the Settings input check.
enum AudioInputCheckTrack: String, CaseIterable, Sendable {
    case microphone
    case meeting

    var label: String {
        switch self {
        case .microphone:
            "You"
        case .meeting:
            "Meeting audio"
        }
    }
}

/// The latest levels are deliberately a value type so a callback can publish
/// them without handing a mutable audio object across isolation domains.
struct AudioInputCheckLevels: Equatable, Sendable {
    let microphone: Double
    let meeting: Double

    static let zero = AudioInputCheckLevels(microphone: 0, meeting: 0)

    var you: Double { microphone }
}

enum AudioInputCheckPhase: Equatable, Sendable {
    case idle
    case starting
    case running
    case stopping
    case failed

    var isActive: Bool {
        switch self {
        case .starting, .running, .stopping:
            true
        case .idle, .failed:
            false
        }
    }
}

/// Starting a second ScreenCaptureKit stream while another local feature is
/// using the microphone is not a useful fallback. A small explicit conflict
/// policy keeps this diagnostic stream from competing with recording or
/// dictation, while leaving the existing meeting arbitration untouched.
enum AudioInputCheckConflict: Equatable, Sendable {
    case meeting
    case dictation
}

/// This is a contract as well as test data. The input check must remain an
/// in-memory meter, not a second recording or transcription path.
struct AudioInputCheckPolicy: Equatable, Sendable {
    let usesRecordingOutput: Bool
    let writesFiles: Bool
    let usesSpeechRecognition: Bool
    let usesModel: Bool
    let usesRecovery: Bool
    let logsEvents: Bool
    let holdsSleepAssertion: Bool

    static let isolated = AudioInputCheckPolicy(
        usesRecordingOutput: false,
        writesFiles: false,
        usesSpeechRecognition: false,
        usesModel: false,
        usesRecovery: false,
        logsEvents: false,
        holdsSleepAssertion: false
    )
}

enum AudioInputCheckError: LocalizedError, Equatable, Sendable {
    case microphonePermissionDenied
    case screenRecordingPermissionDenied
    case noDisplay
    case captureUnavailable
    case conflict(AudioInputCheckConflict)
    case alreadyActive
    case stopFailed

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "Microphone permission is required to test your audio."
        case .screenRecordingPermissionDenied:
            "Screen and System Audio Recording permission is required to test meeting audio. Enable Nook in System Settings, Privacy & Security."
        case .noDisplay:
            "Nook could not find a display for meeting audio."
        case .captureUnavailable:
            "Nook could not start the audio check. Check permissions and try again."
        case .conflict(.meeting):
            "A meeting is active. Stop it before testing audio."
        case .conflict(.dictation):
            "Dictation is active. Stop it before testing audio."
        case .alreadyActive:
            "The audio check is already running."
        case .stopFailed:
            "Nook could not stop the audio check cleanly. Try again."
        }
    }
}

/// A level sample carries the monotonic time at which it arrived. Wall-clock
/// changes must not make a quiet or disconnected input look live.
struct AudioInputCheckLevelSample: Equatable, Sendable {
    let value: Double
    let receivedAt: TimeInterval
}

/// Only start/stop are exposed to the lifecycle controller. Synthetic tests
/// exercise the real ownership transitions without permission or audio access.
@MainActor
protocol AudioInputCheckSession: AnyObject {
    func startCapture() async throws
    func stopCapture() async throws
}

extension SCStream: AudioInputCheckSession {}

/// A short-lived, audio-only ScreenCaptureKit stream for checking the two
/// inputs in Settings. It intentionally has no recording output, file URL,
/// speech recognizer, model, recovery hook, event log, or sleep assertion.
@MainActor
final class AudioInputCheckService: NSObject, ObservableObject, SCStreamDelegate, SCStreamOutput {
    nonisolated static let policy = AudioInputCheckPolicy.isolated

    /// Audio can stop arriving without the stream itself reporting an error.
    /// The first interval fades stale data, then the meter returns to zero.
    nonisolated static let staleAfter: TimeInterval = 0.35
    nonisolated static let silentAfter: TimeInterval = 1.2

    @Published private(set) var phase: AudioInputCheckPhase = .idle
    @Published private(set) var levels = AudioInputCheckLevels.zero
    @Published private(set) var errorMessage: String?
    @Published private(set) var requiredPermission: NookPermission?

    /// A failed stop still owns its stream until ScreenCaptureKit confirms the
    /// teardown. Exposing this lets Settings offer Stop again without ever
    /// allowing a competing Start.
    var isStopAvailable: Bool {
        phase == .starting
            || phase == .running
            || phase == .stopping
            || stream != nil
    }

    private var stream: (any AudioInputCheckSession)?
    private let makeSession: (@MainActor (AudioInputCheckService) async throws -> any AudioInputCheckSession)?

    init(makeSession: (@MainActor (AudioInputCheckService) async throws -> any AudioInputCheckSession)? = nil) {
        self.makeSession = makeSession
        super.init()
    }
    private var streamID: ObjectIdentifier?
    private var startTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var operationID: UInt64 = 0

    /// The callback and the main-actor poller share one lock so an old stream
    /// cannot write a level after stop has cleared the state for a new stream.
    private struct CaptureState: Sendable {
        var activeStreamID: ObjectIdentifier?
        var latest: [AudioInputCheckTrack: AudioInputCheckLevelSample]
    }

    private let captureState = Mutex(
        CaptureState(activeStreamID: nil, latest: [:])
    )
    private let systemAudioQueue = DispatchQueue(
        label: "com.localfirst.nook.audio-input-check.system",
        qos: .userInteractive
    )
    private let microphoneQueue = DispatchQueue(
        label: "com.localfirst.nook.audio-input-check.microphone",
        qos: .userInteractive
    )

    /// A pure policy helper used by AppModel and by tests. Meeting wins when
    /// both features become active in the same turn, producing one stable
    /// message instead of racing two permission paths.
    nonisolated static func conflict(
        meetingIsActive: Bool,
        dictationIsActive: Bool
    ) -> AudioInputCheckConflict? {
        if meetingIsActive {
            return .meeting
        }
        if dictationIsActive {
            return .dictation
        }
        return nil
    }

    nonisolated static func track(for outputType: SCStreamOutputType) -> AudioInputCheckTrack? {
        switch outputType {
        case .microphone:
            .microphone
        case .audio:
            .meeting
        default:
            nil
        }
    }

    /// Returns a monotonic, bounded meter value. The decay is deterministic,
    /// which keeps a temporarily quiet source distinct from a frozen callback.
    nonisolated static func staleAdjustedLevel(
        value: Double,
        receivedAt: TimeInterval?,
        now: TimeInterval
    ) -> Double {
        guard value.isFinite, value >= 0,
              let receivedAt,
              receivedAt.isFinite,
              now.isFinite
        else {
            return 0
        }

        let age = max(0, now - receivedAt)
        guard age > staleAfter else {
            return min(1, value)
        }
        guard age < silentAfter else {
            return 0
        }

        let remaining = 1 - ((age - staleAfter) / (silentAfter - staleAfter))
        return min(1, max(0, value * remaining))
    }

    nonisolated static func percentage(for level: Double) -> Int {
        Int((min(1, max(0, level.isFinite ? level : 0)) * 100).rounded())
    }

    /// Starts asynchronously so Settings remains responsive while macOS
    /// presents or resolves capture permissions.
    @discardableResult
    func start(conflict: AudioInputCheckConflict? = nil) -> Task<Void, Never>? {
        guard phase == .idle || phase == .failed else {
            errorMessage = AudioInputCheckError.alreadyActive.errorDescription
            return nil
        }
        guard startTask == nil, stopTask == nil, stream == nil else {
            errorMessage = AudioInputCheckError.alreadyActive.errorDescription
            return nil
        }

        if let conflict {
            phase = .failed
            errorMessage = AudioInputCheckError.conflict(conflict).errorDescription
            return nil
        }

        operationID &+= 1
        let operation = operationID
        errorMessage = nil
        requiredPermission = nil
        levels = .zero
        captureState.withLock { state in
            state.activeStreamID = nil
            state.latest.removeAll(keepingCapacity: true)
        }
        phase = .starting

        startTask = Task { @MainActor [weak self] in
            await self?.performStart(operation: operation)
        }
        return startTask
    }

    /// A competing capture may proceed only after teardown is confirmed.
    /// Keeping a failed stream is not sufficient if the next caller ignores it.
    func prepareForOtherCapture() async throws {
        await stop()
        guard stream == nil, startTask == nil, stopTask == nil else {
            throw AudioInputCheckError.stopFailed
        }
    }

    /// Stops the stream and waits for ScreenCaptureKit to finish tearing it
    /// down. Keeping this barrier alive prevents a new stream during teardown.
    func stop() async {
        if phase == .stopping {
            if let stopTask {
                await stopTask.value
            } else if let startTask {
                await startTask.value
            }
            return
        }

        guard phase != .idle || stream != nil || startTask != nil else {
            return
        }

        operationID &+= 1
        pollingTask?.cancel()
        pollingTask = nil
        levels = .zero
        clearCaptureState()

        if phase == .starting {
            phase = .stopping
            startTask?.cancel()
            if let startTask {
                await startTask.value
            }
            self.startTask = nil
            // performStart owns cleanup, including a failed stop. Never
            // drop the only handle to audio that may still be running.
            if stream == nil {
                streamID = nil
                phase = .idle
                errorMessage = nil
            }
            return
        }

        guard let stream else {
            phase = .idle
            errorMessage = nil
            return
        }

        phase = .stopping
        let stoppedStreamID = ObjectIdentifier(stream)
        let task = Task { @MainActor [weak self, stream] in
            do {
                try await stream.stopCapture()
                self?.finishStop(
                    streamID: stoppedStreamID,
                    error: nil
                )
            } catch {
                self?.finishStop(
                    streamID: stoppedStreamID,
                    error: error
                )
            }
        }
        stopTask = task
        await task.value
    }

    private func performStart(operation: UInt64) async {
        var candidate: (any AudioInputCheckSession)?
        var didAttemptStart = false
        defer { startTask = nil }
        do {
            try Task.checkCancellation()
            let stream: any AudioInputCheckSession
            if let makeSession {
                stream = try await makeSession(self)
            } else {
                stream = try await makeNativeSession()
            }
            candidate = stream
            try Task.checkCancellation()
            didAttemptStart = true
            try await stream.startCapture()

            guard isCurrentStart(operation) else {
                if await stopCandidate(stream) { finishCanceledStart() }
                return
            }

            self.stream = stream
            self.streamID = ObjectIdentifier(stream)
            captureState.withLock { state in
                state.activeStreamID = ObjectIdentifier(stream)
                state.latest.removeAll(keepingCapacity: true)
            }
            phase = .running
            beginPolling()
        } catch {
            if didAttemptStart, let candidate, !(await stopCandidate(candidate)) { return }
            if Task.isCancelled || phase == .stopping {
                finishCanceledStart()
            } else {
                finishStartFailure(
                    error as? AudioInputCheckError ?? .captureUnavailable,
                    operation: operation
                )
            }
        }
    }

    private func makeNativeSession() async throws -> any AudioInputCheckSession {
        try await requestPermissions()
        try Task.checkCancellation()
        let availableContent = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        guard let display = availableContent.displays.first else {
            throw AudioInputCheckError.noDisplay
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

        let stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: self
        )
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

        return stream
    }

    private func requestPermissions() async throws {
        if !CGPreflightScreenCaptureAccess() {
            guard CGRequestScreenCaptureAccess() else {
                throw AudioInputCheckError.screenRecordingPermissionDenied
            }
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw AudioInputCheckError.microphonePermissionDenied
            }
        case .denied, .restricted:
            throw AudioInputCheckError.microphonePermissionDenied
        @unknown default:
            throw AudioInputCheckError.microphonePermissionDenied
        }
    }

    private func beginPolling() {
        pollingTask?.cancel()
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.phase == .running else { return }
                self.levels = self.currentLevels()
                do {
                    try await Task.sleep(for: .milliseconds(80))
                } catch {
                    return
                }
            }
        }
    }

    private func currentLevels() -> AudioInputCheckLevels {
        let now = ProcessInfo.processInfo.systemUptime
        return captureState.withLock { state in
            AudioInputCheckLevels(
                microphone: Self.staleAdjustedLevel(
                    value: state.latest[.microphone]?.value ?? 0,
                    receivedAt: state.latest[.microphone]?.receivedAt,
                    now: now
                ),
                meeting: Self.staleAdjustedLevel(
                    value: state.latest[.meeting]?.value ?? 0,
                    receivedAt: state.latest[.meeting]?.receivedAt,
                    now: now
                )
            )
        }
    }

    private func isCurrentStart(_ operation: UInt64) -> Bool {
        operation == operationID && phase == .starting && !Task.isCancelled
    }

    private func finishCanceledStart() {
        // Stop advances operationID to reject a late successful start. A new
        // start is barred until startTask releases this cancellation boundary.
        guard phase == .stopping else { return }
        stream = nil
        streamID = nil
        clearCaptureState()
        levels = .zero
        // The stop caller still owns the barrier until its await returns.
        // Publishing idle here could let a new start be erased by that caller.
        errorMessage = nil
    }

    private func finishStartFailure(
        _ error: AudioInputCheckError,
        operation: UInt64
    ) {
        guard operation == operationID, phase == .starting else { return }
        phase = .failed
        errorMessage = error.errorDescription
        switch error {
        case .microphonePermissionDenied: requiredPermission = .microphone
        case .screenRecordingPermissionDenied: requiredPermission = .screenRecording
        default: requiredPermission = nil
        }
        levels = .zero
    }

    private func stopCandidate(_ candidate: any AudioInputCheckSession) async -> Bool {
        // Cleanup needs its own cancellation state after a stopped startup.
        let cleanup = Task { @MainActor in
            try await candidate.stopCapture()
        }
        do {
            try await cleanup.value
            return true
        } catch {
            stream = candidate
            streamID = ObjectIdentifier(candidate)
            phase = .failed
            errorMessage = AudioInputCheckError.stopFailed.errorDescription
            clearCaptureState()
            levels = .zero
            return false
        }
    }

    private func clearCaptureState() {
        captureState.withLock { state in
            state.activeStreamID = nil
            state.latest.removeAll(keepingCapacity: true)
        }
    }

    private func finishStop(streamID: ObjectIdentifier, error: (any Error)?) {
        guard self.streamID == streamID else { return }
        pollingTask?.cancel()
        pollingTask = nil
        clearCaptureState()
        levels = .zero

        if error == nil {
            stream = nil
            self.streamID = nil
            phase = .idle
            errorMessage = nil
        } else {
            // Keep ownership of an uncertain stream. A later Start must not
            // race a stop that ScreenCaptureKit did not confirm.
            phase = .failed
            errorMessage = AudioInputCheckError.stopFailed.errorDescription
        }
        stopTask = nil
    }

    private func handleUnexpectedStop(streamID: ObjectIdentifier) {
        guard self.streamID == streamID else { return }
        guard phase != .stopping else { return }
        pollingTask?.cancel()
        pollingTask = nil
        clearCaptureState()
        stream = nil
        self.streamID = nil
        levels = .zero
        phase = .failed
        errorMessage = AudioInputCheckError.captureUnavailable.errorDescription
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid, sampleBuffer.dataReadiness == .ready,
              let track = Self.track(for: outputType)
        else {
            return
        }

        let level = Self.normalizedAudioLevel(in: sampleBuffer)
        let streamID = ObjectIdentifier(stream)
        let sample = AudioInputCheckLevelSample(
            value: level,
            receivedAt: ProcessInfo.processInfo.systemUptime
        )
        captureState.withLock { state in
            guard state.activeStreamID == streamID else { return }
            state.latest[track] = sample
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError _: any Error) {
        let stoppedStreamID = ObjectIdentifier(stream)
        Task { @MainActor [weak self] in
            self?.handleUnexpectedStop(streamID: stoppedStreamID)
        }
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
        guard rms > 0, rms.isFinite else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels + 55) / 55))
    }
}
