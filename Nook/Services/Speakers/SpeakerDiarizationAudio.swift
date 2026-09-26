import AVFoundation
import FluidAudio
import Foundation

/// A recording converted once to what the diarization models read: 16 kHz
/// mono Float32.
///
/// Memory: the converted samples are streamed to a private temporary file in
/// fixed-size chunks and then memory-mapped, so an hour of audio (about 230 MB
/// of samples) is never held as one array. The pipeline copies out one
/// 10-second window at a time and the kernel pages the rest in and out as
/// needed. The file is unlinked as soon as it is mapped, so the converted
/// audio disappears with the mapping even if the app is quit mid-analysis.
struct DiarizationAudio: AudioSampleSource {
    static let sampleRate = 16_000

    private let samples: Data
    let sampleCount: Int

    var duration: TimeInterval { Double(sampleCount) / Double(Self.sampleRate) }

    /// Reads `audioURL` with AVFoundation and converts it with
    /// `AVAudioConverter`. Channels are mixed down rather than dropped: a
    /// remote speaker can sit on either side of a stereo system-audio track.
    ///
    /// Throws `SpeakerDiarizationError.unreadableAudio` when the file cannot
    /// be decoded or holds no audio, and `CancellationError` promptly when the
    /// calling task is cancelled.
    static func load(_ audioURL: URL) throws -> DiarizationAudio {
        try Task.checkCancellation()
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: audioURL)
        } catch {
            throw SpeakerDiarizationError.unreadableAudio
        }
        let input = file.processingFormat
        guard file.length > 0, input.sampleRate > 0, input.channelCount > 0,
              let output = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: Double(sampleRate),
                  channels: 1,
                  interleaved: false
              ),
              let converter = AVAudioConverter(from: input, to: output) else {
            throw SpeakerDiarizationError.unreadableAudio
        }
        converter.downmix = true

        let manager = FileManager.default
        let directory = try manager.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: audioURL, create: true
        )
        defer { try? manager.removeItem(at: directory) }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let samplesURL = directory.appendingPathComponent("samples.f32")
        guard manager.createFile(
            atPath: samplesURL.path, contents: nil, attributes: [.posixPermissions: 0o600]
        ) else {
            throw SpeakerDiarizationError.unreadableAudio
        }

        let handle = try FileHandle(forWritingTo: samplesURL)
        let written: Int
        do {
            written = try convert(file, with: converter, into: handle)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard written > 0 else { throw SpeakerDiarizationError.unreadableAudio }

        let mapped = try Data(contentsOf: samplesURL, options: .alwaysMapped)
        // The mapping keeps the pages alive after unlinking, and nothing else
        // may read the converted audio in the meantime.
        try manager.removeItem(at: samplesURL)
        return DiarizationAudio(samples: mapped, sampleCount: mapped.count / MemoryLayout<Float>.stride)
    }

    func copySamples(
        into destination: UnsafeMutablePointer<Float>,
        offset: Int,
        count: Int
    ) throws {
        // The pipeline may ask past the end for its last, padded window; it
        // zero-fills that remainder itself, so only the overlap is copied.
        let start = max(0, offset)
        guard count > 0, start < sampleCount else { return }
        let available = min(sampleCount - start, count)
        samples.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            guard let base = floats.baseAddress else { return }
            destination.update(from: base.advanced(by: start), count: available)
        }
    }

    /// Streams `file` through `converter` into `handle` and returns the number
    /// of output samples written.
    private static func convert(
        _ file: AVAudioFile,
        with converter: AVAudioConverter,
        into handle: FileHandle
    ) throws -> Int {
        let chunkFrames: AVAudioFrameCount = 65_536
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        // Sample-rate conversion is stateful and can emit a little more than
        // the ratio suggests, so each output buffer carries headroom.
        let outputCapacity = AVAudioFrameCount((Double(chunkFrames) * ratio).rounded(.up)) + 1_024
        guard let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: chunkFrames),
              let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: outputCapacity)
        else {
            throw SpeakerDiarizationError.unreadableAudio
        }

        var written = 0
        while true {
            try Task.checkCancellation()
            // Reading at the end of a file throws rather than returning zero
            // frames, so the remaining length decides when to stop.
            let remaining = file.length - file.framePosition
            guard remaining > 0 else { break }
            do {
                try file.read(into: input, frameCount: AVAudioFrameCount(min(Int64(chunkFrames), remaining)))
            } catch {
                throw SpeakerDiarizationError.unreadableAudio
            }
            guard input.frameLength > 0 else { break }
            // `.noDataNow` keeps the converter open for the next chunk.
            // `.endOfStream` is terminal and is only sent once, below.
            written += try drain(converter, input: input, whenStarved: .noDataNow, into: output, handle: handle)
        }
        written += try drain(converter, input: nil, whenStarved: .endOfStream, into: output, handle: handle)
        return written
    }

    private static func drain(
        _ converter: AVAudioConverter,
        input: AVAudioPCMBuffer?,
        whenStarved: AVAudioConverterInputStatus,
        into output: AVAudioPCMBuffer,
        handle: FileHandle
    ) throws -> Int {
        // The same one-shot provider live transcription uses: the buffer is
        // handed over once, however often the converter asks.
        let provider = AnalyzerInputBufferProvider(buffer: input)
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            guard let buffer = provider.takeBuffer() else {
                status.pointee = whenStarved
                return nil
            }
            status.pointee = .haveData
            return buffer
        }

        var written = 0
        while true {
            output.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError, withInputFrom: inputBlock)
            if status == .error {
                throw SpeakerDiarizationError.unreadableAudio
            }
            let frames = Int(output.frameLength)
            if frames > 0, let channel = output.floatChannelData?[0] {
                try handle.write(contentsOf: Data(bytes: channel, count: frames * MemoryLayout<Float>.stride))
                written += frames
            }
            // `.haveData` means the output filled up and more may be waiting.
            guard status == .haveData, frames > 0 else { return written }
        }
    }
}
