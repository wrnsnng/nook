import AVFoundation

@MainActor
protocol DictationAudioCapturing: AnyObject {
    var onLevel: (@MainActor (Float) -> Void)? { get set }
    func start(
        onBuffer: @escaping @MainActor (AVAudioPCMBuffer) -> Void
    ) throws
    func finishCapturing() async
    func stop()
}

/// Microphone capture for dictation.
///
/// Deliberately not `CaptureService`. That path reaches the microphone through
/// ScreenCaptureKit, which means it also requires Screen & System Audio
/// Recording permission — reasonable for a meeting, indefensible for typing a
/// sentence into a text field. `AVAudioEngine` needs only the microphone grant
/// the user has already given.
@MainActor
final class DictationAudioSource: DictationAudioCapturing {
    enum SourceError: LocalizedError {
        case noInputAvailable

        var errorDescription: String? {
            switch self {
            case .noInputAvailable:
                "No microphone is available right now."
            }
        }
    }

    /// One buffer with the level already measured, so both travel together and
    /// the indicator can never disagree with the audio it came from.
    private struct TappedAudio: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let level: Float
    }

    private let engine = AVAudioEngine()
    private var isRunning = false
    private var continuation: AsyncStream<TappedAudio>.Continuation?
    private var pump: Task<Void, Never>?

    /// Reports the running input level, 0...1, for the dictation indicator.
    var onLevel: (@MainActor (Float) -> Void)?

    func start(
        onBuffer: @escaping @MainActor (AVAudioPCMBuffer) -> Void
    ) throws {
        guard !isRunning else { return }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // A disconnected or in-use device reports a zero-rate format, and
        // installing a tap on it traps rather than throwing.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SourceError.noInputAvailable
        }

        // Buffers reach the recognizer through one ordered stream drained by a
        // single task. Spawning a `Task` per buffer instead would hand each one
        // to the main actor independently, and unstructured tasks carry no
        // ordering guarantee — reordered audio corrupts recognition in ways
        // that look like the recognizer simply mishearing.
        let pair = AsyncStream<TappedAudio>.makeStream(
            bufferingPolicy: .bufferingNewest(240)
        )
        continuation = pair.continuation
        pump = Task { @MainActor [weak self] in
            for await tapped in pair.stream {
                self?.onLevel?(tapped.level)
                onBuffer(tapped.buffer)
            }
        }

        let continuation = pair.continuation
        // Typed `@Sendable` deliberately. `AVAudioNodeTapBlock` is not marked
        // sendable in the SDK, so a closure written inline here inherits this
        // class's `@MainActor` isolation — and AVFoundation calls it on its own
        // real-time queue, which traps the executor check on the first buffer.
        // The annotation is what makes the closure non-isolated; everything it
        // touches must be non-isolated too.
        let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            // The tap owns this buffer and reuses it after the callback
            // returns, so it has to be copied before it can leave the
            // real-time thread. `yield` is thread-safe and order-preserving.
            guard let copy = buffer.copied() else { return }
            continuation.yield(
                TappedAudio(
                    buffer: copy,
                    level: DictationAudioSource.normalizedLevel(in: copy)
                )
            )
        }
        input.installTap(
            onBus: 0,
            bufferSize: 4_096,
            format: format,
            block: tap
        )

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            continuation.finish()
            pump?.cancel()
            pump = nil
            self.continuation = nil
            throw error
        }
        isRunning = true
    }

    /// Stops capture and waits for audio already in the pipe to be delivered.
    ///
    /// The last buffers are usually the end of the user's final word, and the
    /// recognizer cannot be finalized until they have arrived.
    func finishCapturing() async {
        guard closeInput() else { return }
        // An abandoned drain can outlive the session that started it, by which
        // point `pump` may belong to a newer one. Clearing it unconditionally
        // would leave that session unable to drain its own trailing audio.
        let draining = pump
        await draining?.value
        if pump == draining { pump = nil }
    }

    /// Stops capture immediately and discards anything still in flight. For
    /// cancellation and start-up failures, where the audio is not wanted.
    func stop() {
        guard closeInput() else { return }
        pump?.cancel()
        pump = nil
    }

    /// Tears down the tap and closes the stream. Returns whether there was a
    /// running session to close.
    private func closeInput() -> Bool {
        guard isRunning else { return false }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        return true
    }

    /// Runs on the audio tap's real-time queue, so it must stay off the main
    /// actor that its enclosing type otherwise imposes.
    private nonisolated static func normalizedLevel(
        in buffer: AVAudioPCMBuffer
    ) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else {
            return 0
        }
        let frames = Int(buffer.frameLength)
        var sum: Float = 0
        for frame in 0..<frames {
            let sample = channels[0][frame]
            sum += sample * sample
        }
        let rms = (sum / Float(frames)).squareRoot()
        // Speech sits well below full scale, so the raw RMS barely moves the
        // indicator. This maps a realistic voice range onto 0...1.
        return min(1, max(0, rms * 12))
    }
}

extension AVAudioPCMBuffer {
    /// An independent copy that outlives the buffer it was taken from.
    func copied() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameLength
        ) else {
            return nil
        }
        copy.frameLength = frameLength

        let channels = Int(format.channelCount)
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        // The typed channel accessors address one contiguous block per channel,
        // which is only how non-interleaved buffers are laid out. An interleaved
        // buffer copied that way would come out silently wrong, so it takes the
        // raw buffer-list path below instead.
        if !format.isInterleaved,
           let source = floatChannelData, let destination = copy.floatChannelData {
            for channel in 0..<channels {
                destination[channel].update(
                    from: source[channel],
                    count: Int(frameLength)
                )
            }
            return copy
        }
        if !format.isInterleaved,
           let source = int16ChannelData, let destination = copy.int16ChannelData {
            for channel in 0..<channels {
                destination[channel].update(
                    from: source[channel],
                    count: Int(frameLength)
                )
            }
            return copy
        }
        guard bytesPerFrame > 0 else { return nil }
        // Fall back to the raw buffer list for any format the typed accessors
        // do not expose.
        let sourceList = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let destinationList = UnsafeMutableAudioBufferListPointer(
            copy.mutableAudioBufferList
        )
        guard sourceList.count == destinationList.count else { return nil }
        for index in 0..<sourceList.count {
            guard let from = sourceList[index].mData,
                  let to = destinationList[index].mData
            else {
                return nil
            }
            let size = min(
                Int(sourceList[index].mDataByteSize),
                Int(destinationList[index].mDataByteSize)
            )
            memcpy(to, from, size)
        }
        return copy
    }
}
