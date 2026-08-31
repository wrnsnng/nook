import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import Nook

/// Live captions depend on reshaping ScreenCaptureKit audio into the format
/// `SpeechAnalyzer` asks for. When that conversion silently stops working the
/// app still records, so nothing else in the suite notices. These tests pin the
/// behavior directly.
struct LiveAnalyzerInputTests {
    /// The exact shape ScreenCaptureKit delivers, per `CaptureService`.
    private func captureFormat() throws -> AVAudioFormat {
        try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 2,
                interleaved: false
            )
        )
    }

    /// A representative `SpeechAnalyzer` format: lower rate, single channel.
    private func analyzerFormat() throws -> AVAudioFormat {
        try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
    }

    private func tone(
        format: AVAudioFormat,
        frames: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        )
        buffer.frameLength = frames
        let channels = try #require(buffer.floatChannelData)
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(frames) {
                let phase = Double(frame) / format.sampleRate * 440 * 2 * .pi
                channels[channel][frame] = Float(sin(phase) * 0.5)
            }
        }
        return buffer
    }

    @Test
    func captureAudioConvertsIntoTheAnalyzerFormat() throws {
        let analyzerFormat = try analyzerFormat()
        let converter = ResamplingAnalyzerInputConverter(
            analyzerFormat: analyzerFormat
        )
        let captured = try tone(format: try captureFormat(), frames: 4_800)

        let converted = try converter.convertToBuffers(captured)

        let output = try #require(converted.first)
        #expect(converted.count == 1)
        #expect(output.format == analyzerFormat)
        #expect(output.frameLength > 0)
        // 48 kHz → 16 kHz is a third of the frames: 4,800 → 1,600. The first
        // buffer is shorter because the resampler swallows ~240 frames priming
        // its filter; `aContinuousStreamKeepsConverting` covers steady state.
        #expect(output.frameLength <= 1_600)
        #expect(output.frameLength >= 1_300)
    }

    /// The regression that broke live transcription: a converter that only
    /// passed through exactly-matching formats produced nothing at all, because
    /// capture audio never matches the analyzer format.
    @Test
    func mismatchedCaptureAudioIsNotDropped() throws {
        let converter = ResamplingAnalyzerInputConverter(
            analyzerFormat: try analyzerFormat()
        )
        let captured = try tone(format: try captureFormat(), frames: 4_800)

        #expect(captured.format != (try analyzerFormat()))
        #expect(try converter.convertToBuffers(captured).isEmpty == false)
    }

    @Test
    func matchingFormatsPassStraightThrough() throws {
        let analyzerFormat = try analyzerFormat()
        let converter = ResamplingAnalyzerInputConverter(
            analyzerFormat: analyzerFormat
        )
        let buffer = try tone(format: analyzerFormat, frames: 1_600)

        let converted = try converter.convertToBuffers(buffer)

        #expect(converted.count == 1)
        #expect(converted.first === buffer)
    }

    @Test
    func aContinuousStreamKeepsConverting() throws {
        let converter = ResamplingAnalyzerInputConverter(
            analyzerFormat: try analyzerFormat()
        )
        let captureFormat = try captureFormat()

        var totalFrames: AVAudioFrameCount = 0
        for _ in 0..<25 {
            let captured = try tone(format: captureFormat, frames: 4_800)
            for output in try converter.convertToBuffers(captured) {
                totalFrames += output.frameLength
            }
        }

        // 25 × 100 ms of 48 kHz audio is ~2.5 s, or ~40,000 frames at 16 kHz.
        #expect(totalFrames > 38_000)
        #expect(totalFrames < 42_000)
    }

    @Test
    func flushingCompletesTheAudioOnceWithoutRepeatingTheTail() throws {
        let converter = ResamplingAnalyzerInputConverter(
            analyzerFormat: try analyzerFormat()
        )
        let format = try captureFormat()
        var totalFrames: AVAudioFrameCount = 0
        for _ in 0..<25 {
            let captured = try tone(format: format, frames: 4_800)
            for output in try converter.convertToBuffers(captured) {
                totalFrames += output.frameLength
            }
        }

        for output in try converter.flushBuffers() {
            totalFrames += output.frameLength
        }

        // A duplicated input or a discarded resampler tail changes the saved
        // speech timeline. Exactly 2.5 seconds must survive the full stream.
        #expect(totalFrames == 40_000)
        #expect(try converter.flushBuffers().isEmpty)
    }

    @Test
    func concurrentInputRequestsReceiveTheAudioOnlyOnce() throws {
        let buffer = try tone(format: try captureFormat(), frames: 4_800)
        let provider = AnalyzerInputBufferProvider(buffer: buffer)
        let suppliedFrames = Mutex<[AVAudioFrameCount]>([])

        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            guard let supplied = provider.takeBuffer() else { return }
            suppliedFrames.withLock { $0.append(supplied.frameLength) }
        }

        #expect(suppliedFrames.withLock { $0 } == [4_800])
        #expect(provider.takeBuffer() == nil)
    }

    @Test
    func emptyBuffersProduceNoInput() throws {
        let converter = ResamplingAnalyzerInputConverter(
            analyzerFormat: try analyzerFormat()
        )
        let captureFormat = try captureFormat()
        let empty = try #require(
            AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: 4_800)
        )
        empty.frameLength = 0

        #expect(try converter.convertToBuffers(empty).isEmpty)
    }

    @Test
    func flushingBeforeAnyAudioIsSafe() throws {
        let converter = ResamplingAnalyzerInputConverter(
            analyzerFormat: try analyzerFormat()
        )

        #expect(try converter.flushBuffers().isEmpty)
    }

    @Test
    func theShippedConverterResamples() throws {
        // `makeLiveInputConverter` previously returned a pass-through converter
        // whenever the building toolchain lacked the macOS 27 SDK, which is how
        // release builds lost live captions while local builds kept them.
        let converter = makeLiveInputConverter(
            analyzerFormat: try analyzerFormat()
        )

        #expect(converter is ResamplingAnalyzerInputConverter)
    }
}
