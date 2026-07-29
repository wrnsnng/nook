import AVFoundation
import AudioToolbox
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Synchronization

@MainActor
final class CaptureService: NSObject, SCStreamDelegate, SCRecordingOutputDelegate, SCStreamOutput {
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var recordingURL: URL?
    private var baseRecordingURL: URL?
    private var recordingURLs: [URL] = []
    private var nextSegmentNumber = 2
    private(set) var isPaused = false
    private var finishContinuation: CheckedContinuation<Void, Error>?
    private let preparesLiveInput = Mutex(false)
    private weak var liveTranscription: LiveTranscriptionService?
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

    var isCapturing: Bool { stream != nil }

    func attachLiveTranscription(_ service: LiveTranscriptionService) {
        guard stream != nil else { return }
        liveTranscription = service
        preparesLiveInput.withLock { $0 = !isPaused }
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
        guard stream == nil else { throw CaptureError.alreadyRecording }
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
        self.recordingURL = url
        self.baseRecordingURL = url
        self.recordingURLs = [url]
        self.nextSegmentNumber = 2
        self.recordingOutput = recordingOutput
        self.stream = stream
        self.isPaused = false
        self.liveTranscription = nil
        self.audioLevelHandler = onAudioLevel

        do {
            try await stream.startCapture()
        } catch {
            self.stream = nil
            self.recordingOutput = nil
            self.recordingURL = nil
            throw error
        }
    }

    func pause() async throws {
        guard let stream, let recordingOutput, !isPaused else {
            throw isPaused ? CaptureError.alreadyPaused : CaptureError.notRecording
        }

        preparesLiveInput.withLock { $0 = false }
        isPaused = true
        do {
            try await withCheckedThrowingContinuation { continuation in
                finishContinuation = continuation
                do {
                    try stream.removeRecordingOutput(recordingOutput)
                } catch {
                    completeStop(with: error)
                }
            }
            self.recordingOutput = nil
            recordingURL = nil
        } catch {
            isPaused = false
            preparesLiveInput.withLock { $0 = liveTranscription != nil }
            throw error
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
        isPaused = false
        preparesLiveInput.withLock { $0 = liveTranscription != nil }
    }

    func stop() async throws -> [URL] {
        guard let stream, !recordingURLs.isEmpty else {
            throw CaptureError.notRecording
        }

        let completedURLs = recordingURLs
        if isPaused {
            do {
                try await stream.stopCapture()
            } catch {
                clear()
                throw error
            }
        } else {
            do {
                try await withCheckedThrowingContinuation { continuation in
                    finishContinuation = continuation
                    Task { @MainActor in
                        do {
                            try await stream.stopCapture()
                        } catch {
                            completeStop(with: error)
                        }
                    }
                }
            } catch {
                clear()
                throw error
            }
        }
        clear()

        if let lastError {
            throw lastError
        }
        let existingURLs = completedURLs.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard !existingURLs.isEmpty else {
            throw CaptureError.recordingMissing
        }
        return existingURLs
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in
            self.lastError = error
            self.completeStop(with: error)
        }
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
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
        let liveInput: CapturedAudioBuffer? = if preparesLiveInput.withLock({ $0 }),
           let buffer = Self.pcmBuffer(from: sampleBuffer) {
            CapturedAudioBuffer(buffer: buffer)
        } else {
            nil
        }

        Task { @MainActor [weak self] in
            self?.audioLevelHandler?(level, source)
            guard let liveInput else { return }
            self?.liveTranscription?.ingest(
                liveInput.buffer,
                source: source
            )
        }
    }

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {}

    nonisolated func recordingOutput(
        _ recordingOutput: SCRecordingOutput,
        didFailWithError error: any Error
    ) {
        Task { @MainActor in
            self.lastError = error
            self.completeStop(with: error)
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            self.completeStop()
        }
    }

    private func completeStop(with error: Error? = nil) {
        guard let continuation = finishContinuation else { return }
        finishContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    private func clear() {
        stream = nil
        recordingOutput = nil
        recordingURL = nil
        baseRecordingURL = nil
        recordingURLs = []
        nextSegmentNumber = 2
        isPaused = false
        finishContinuation = nil
        liveTranscription = nil
        audioLevelHandler = nil
        preparesLiveInput.withLock { $0 = false }
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
private struct CapturedAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
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
        }
    }
}
