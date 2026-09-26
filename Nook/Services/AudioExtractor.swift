import AVFoundation
import Foundation

enum AudioExtractor {
    typealias Export = @Sendable (AVAsset, AVAudioMix, URL) async throws -> Void

    static func extractAudio(from recordingURL: URL, to audioURL: URL) async throws {
        try await extractAudio(from: [recordingURL], to: audioURL)
    }

    static func extractAudio(
        from recordingURLs: [URL],
        to audioURL: URL,
        export: Export? = nil,
        cleanup: @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) async throws {
        try Task.checkCancellation()
        guard !recordingURLs.isEmpty else {
            throw AudioExtractionError.noAudioTrack
        }
        let selection = try SourceAudioFiles.select(recordingURLs)
        let inputs = try selection.urls.map { try NoteCombiner.AudioFileSnapshot(url: $0) }
        let destination = try NoteCombiner.AudioFileSnapshot(url: audioURL)
        guard inputs.allSatisfy(\.exists),
              !(inputs + selection.snapshots).contains(where: { $0.refersToSameFile(as: destination) }) else {
            throw AudioExtractionError.filesChanged
        }

        let composition = AVMutableComposition()
        // AVAssetTrack refers weakly to its asset. Keep those owners alive
        // through asynchronous range loading, composition and export.
        var assets: [AVURLAsset] = []
        defer { withExtendedLifetime(assets) {} }
        var lanes: [AVMutableCompositionTrack] = []
        var parameters: [AVMutableAudioMixInputParameters] = []
        var insertionTime = CMTime.zero
        var lastAudioEnd = CMTime.zero
        for recordingURL in selection.urls {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: recordingURL)
            assets.append(asset)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard !audioTracks.isEmpty else { throw AudioExtractionError.noAudioTrack }
            let duration = try await asset.load(.duration)
            guard duration.isNumeric, duration.seconds.isFinite, duration > .zero else {
                throw AudioExtractionError.invalidTimeline
            }
            var partEnd = insertionTime + duration
            // Track indices are only reusable mixing lanes, never speaker
            // identities. Every track contributes, even when a later capture
            // part changes its track count, order or channel configuration.
            for (index, sourceTrack) in audioTracks.enumerated() {
                try Task.checkCancellation()
                let range = try await sourceTrack.load(.timeRange)
                guard range.isValid, range.start.isNumeric, range.duration.isNumeric,
                      range.start.seconds.isFinite, range.duration.seconds.isFinite,
                      range.start >= .zero, range.duration > .zero else {
                    throw AudioExtractionError.invalidTimeline
                }
                if index == lanes.count {
                    guard let lane = composition.addMutableTrack(
                        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
                    ) else { throw AudioExtractionError.cannotCreateExporter }
                    lanes.append(lane)
                    parameters.append(AVMutableAudioMixInputParameters(track: lane))
                }
                let start = insertionTime + range.start
                let end = start + range.duration
                guard start.isNumeric, end.isNumeric, end.seconds.isFinite else {
                    throw AudioExtractionError.invalidTimeline
                }
                try lanes[index].insertTimeRange(range, of: sourceTrack, at: start)
                lastAudioEnd = CMTimeMaximum(lastAudioEnd, end)
                // Fixed per-part headroom retains every source without
                // clipping when microphone and system tracks peak together.
                parameters[index].setVolume(1 / Float(audioTracks.count), at: insertionTime)
                partEnd = CMTimeMaximum(partEnd, end)
            }
            // A video part can continue after its final audio sample. Keep
            // that silence so resumed speech and transcript playback share
            // the original unpaused timeline instead of closing the gap.
            if composition.duration < partEnd {
                composition.insertEmptyTimeRange(CMTimeRange(
                    start: composition.duration, duration: partEnd - composition.duration
                ))
            }
            insertionTime = partEnd
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        let manager = FileManager.default
        // Exporters require a nonexistent output. A private same-volume
        // replacement directory avoids deleting the previous complete audio
        // before export, and prevents another recovery from seeing a partial
        // M4A as a completed extracted recording.
        let stagingDirectory = try manager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: audioURL, create: true
        )
        var exportFailure: (any Error)?
        do {
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stagingDirectory.path)
            if lastAudioEnd < insertionTime {
                // AppleM4A export drops a final empty edit even with an
                // explicit timeRange. A short silent endpoint makes it render
                // the preceding gap too, without materializing hours of PCM.
                let silenceURL = stagingDirectory.appendingPathComponent("silence.caf")
                try writeSilentEndpoint(to: silenceURL)
                let silence = AVURLAsset(url: silenceURL)
                assets.append(silence)
                guard let source = try await silence.loadTracks(withMediaType: .audio).first,
                      let lane = composition.addMutableTrack(
                        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
                      ) else { throw AudioExtractionError.cannotCreateExporter }
                let length = CMTimeMinimum(insertionTime - lastAudioEnd,
                                           CMTime(value: 4_800, timescale: 48_000))
                try lane.insertTimeRange(CMTimeRange(start: .zero, duration: length),
                                         of: source, at: insertionTime - length)
            }
            let staged = stagingDirectory.appendingPathComponent("audio.m4a")
            try await (export ?? exportAudio)(composition, mix, staged)
            try Task.checkCancellation()
            let exported = AVURLAsset(url: staged)
            let exportedTracks = try await exported.loadTracks(withMediaType: .audio)
            let exportedDuration = try await exported.load(.duration)
            guard !exportedTracks.isEmpty, exportedDuration.isNumeric,
                  abs(exportedDuration.seconds - insertionTime.seconds) <= 0.05 else {
                throw AudioExtractionError.invalidExport
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
            try Task.checkCancellation()
            // These metadata checks narrow replacement races; they are not a
            // transaction against an uncooperative concurrent filesystem writer.
            do {
                for input in inputs { try input.validate() }
                try selection.validate()
                try destination.validate()
            } catch { throw AudioExtractionError.filesChanged }
            if destination.exists {
                _ = try manager.replaceItemAt(audioURL, withItemAt: staged, options: .usingNewMetadataOnly)
            } else {
                try manager.moveItem(at: staged, to: audioURL)
            }
        } catch { exportFailure = error }
        do { try cleanup(stagingDirectory) }
        catch {
            // A cleanup error must identify the leftover directory, not hide
            // another local copy of audio behind an apparent success.
            throw AudioExtractionError.cleanupFailed(stagingDirectory)
        }
        if let exportFailure { throw exportFailure }
    }

    private static func writeSilentEndpoint(to url: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800),
              let samples = buffer.floatChannelData else {
            throw AudioExtractionError.cannotCreateExporter
        }
        buffer.frameLength = buffer.frameCapacity
        samples[0].initialize(repeating: 0, count: Int(buffer.frameLength))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private static func exportAudio(
        _ asset: AVAsset, _ mix: AVAudioMix, _ audioURL: URL
    ) async throws {
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw AudioExtractionError.cannotCreateExporter
        }
        exporter.audioMix = mix
        exporter.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        try await exporter.export(to: audioURL, as: .m4a)
    }
}

enum AudioExtractionError: LocalizedError {
    case noAudioTrack
    case cannotCreateExporter
    case invalidTimeline
    case invalidExport
    case filesChanged
    case cleanupFailed(URL)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            "The recording did not contain an audio track."
        case .cannotCreateExporter:
            "Nook could not prepare the meeting audio for transcription."
        case .invalidTimeline:
            "A recording part has an unreadable audio timeline. The original recording was kept."
        case .invalidExport:
            "The extracted audio could not be verified. The original recording was kept."
        case .filesChanged:
            "The recording files changed while audio was being prepared. Try again with the current files."
        case .cleanupFailed(let directory):
            "Nook could not remove the temporary audio folder at \(directory.path). The original recording was kept."
        }
    }
}
