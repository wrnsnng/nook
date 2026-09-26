import AVFoundation
import Foundation

/// Source is a property of the capture input, never a guess about a person's
/// voice, track position or channel count. SourceAudioRecording attaches this
/// exact versioned marker to the typed input it receives from ScreenCaptureKit.
enum RecordedAudioSource {
    static let prefix = "nook:audio-source:v1:"

    static func metadata(for source: TranscriptSegment.Source) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataInformation
        item.value = (prefix + source.rawValue) as NSString
        return item
    }

    static func source(in metadata: [AVMetadataItem]) async throws -> TranscriptSegment.Source {
        var markers: [String] = []
        for item in metadata where item.identifier == .quickTimeMetadataInformation {
            if let value = try await item.load(.stringValue), value.hasPrefix("nook:audio-source:") {
                markers.append(value)
            }
        }
        // Duplicate, conflicting and future-version markers cannot authorize
        // attribution. A human-readable track title is not this protocol.
        guard markers.count == 1 else { return .mixed }
        switch markers[0] {
        case prefix + "microphone": return .microphone
        case prefix + "system": return .system
        default: return .mixed
        }
    }
}

enum RecordedSourceTranscription {
    typealias Operation = @Sendable (URL, String) async throws -> [TranscriptSegment]

    /// Returns nil only when no track carries recognized capture provenance.
    /// Once any source is known, every track of every ordered part participates,
    /// including unknown tracks. A failed track fails the whole operation so a
    /// partial result cannot quietly replace the only complete recording.
    static func transcribeIfLabelled(
        recordingURLs: [URL], localeIdentifier: String, operation: Operation,
        cleanup: @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) async throws -> [TranscriptSegment]? {
        guard !recordingURLs.isEmpty else { return nil }
        try Task.checkCancellation()
        let snapshots = try recordingURLs.map { try NoteCombiner.AudioFileSnapshot(url: $0) }
        guard snapshots.allSatisfy(\.exists) else { throw AudioExtractionError.filesChanged }
        var assets: [AVURLAsset] = []
        defer { withExtendedLifetime(assets) {} }
        var inputs: [Input] = []
        var partStart = 0.0
        for url in recordingURLs {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: url)
            assets.append(asset)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard !tracks.isEmpty else { throw AudioExtractionError.noAudioTrack }
            let duration = try await asset.load(.duration)
            guard duration.isNumeric, duration.seconds.isFinite, duration > .zero else {
                throw AudioExtractionError.invalidTimeline
            }
            var partDuration = duration.seconds
            for track in tracks {
                let range = try await track.load(.timeRange)
                guard range.isValid, range.start.isNumeric, range.duration.isNumeric,
                      range.start.seconds.isFinite, range.end.seconds.isFinite,
                      range.start >= .zero, range.duration > .zero else {
                    throw AudioExtractionError.invalidTimeline
                }
                let metadata = try await track.load(.metadata)
                let source = try await RecordedAudioSource.source(in: metadata)
                inputs.append(Input(track: track, range: range, offset: partStart + range.start.seconds, source: source))
                partDuration = max(partDuration, range.end.seconds)
            }
            partStart += partDuration
            guard partStart.isFinite else { throw AudioExtractionError.invalidTimeline }
        }
        try Task.checkCancellation()
        try validate(snapshots)
        guard inputs.contains(where: { $0.source != .mixed }) else { return nil }

        let manager = FileManager.default
        let directory = try manager.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: recordingURLs[0], create: true
        )
        var outcome: Result<[TranscriptSegment], any Error>
        do {
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            var result: [TranscriptSegment] = []
            // One ordered consumer bounds temporary disk use and avoids two
            // independent Speech analyzers fighting over the same asset.
            for (index, input) in inputs.enumerated() {
                try Task.checkCancellation()
                try validate(snapshots)
                let temporary = directory.appendingPathComponent("track-\(index).m4a")
                try await export(input, to: temporary)
                try validate(snapshots)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
                try Task.checkCancellation()
                let segments = try await operation(temporary, localeIdentifier)
                try Task.checkCancellation()
                try validate(snapshots)
                for segment in segments {
                    guard segment.startTime.isFinite, segment.duration.isFinite,
                          segment.startTime >= 0, segment.duration >= 0,
                          segment.startTime + segment.duration <= input.range.duration.seconds + 0.05 else {
                        throw AudioExtractionError.invalidTimeline
                    }
                    result.append(TranscriptSegment(
                        id: segment.id, startTime: input.offset + segment.startTime,
                        duration: segment.duration, text: segment.text, source: input.source
                    ))
                }
                try manager.removeItem(at: temporary)
            }
            try validate(snapshots)
            // Equal timestamps retain file/track/result order. Do not use the
            // live echo deduplicator: identical words on two stored tracks are
            // still two pieces of captured evidence, not permission to erase one.
            outcome = .success(result.enumerated().sorted {
                $0.element.startTime == $1.element.startTime
                    ? $0.offset < $1.offset : $0.element.startTime < $1.element.startTime
            }.map(\.element))
        } catch { outcome = .failure(error) }
        do { try cleanup(directory) }
        catch { throw AudioExtractionError.cleanupFailed(directory) }
        return try outcome.get()
    }

    private struct Input {
        let track: AVAssetTrack
        let range: CMTimeRange
        let offset: TimeInterval
        let source: TranscriptSegment.Source
    }

    private static func validate(_ snapshots: [NoteCombiner.AudioFileSnapshot]) throws {
        do { for snapshot in snapshots { try snapshot.validate() } }
        catch { throw AudioExtractionError.filesChanged }
    }

    private static func export(_ input: Input, to url: URL) async throws {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw AudioExtractionError.cannotCreateExporter }
        // Trim only the leading offset of this isolated track. Put that exact
        // offset back onto every result; part length still includes silent tails.
        try track.insertTimeRange(input.range, of: input.track, at: .zero)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A)
        else { throw AudioExtractionError.cannotCreateExporter }
        try await exporter.export(to: url, as: .m4a)
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty,
              duration.isNumeric, abs(duration.seconds - input.range.duration.seconds) <= 0.05 else {
            throw AudioExtractionError.invalidExport
        }
    }
}
