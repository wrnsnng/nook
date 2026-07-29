import AVFoundation
import Foundation

enum AudioExtractor {
    static func extractAudio(from recordingURL: URL, to audioURL: URL) async throws {
        try await extractAudio(from: [recordingURL], to: audioURL)
    }

    static func extractAudio(
        from recordingURLs: [URL],
        to audioURL: URL
    ) async throws {
        guard let firstURL = recordingURLs.first else {
            throw AudioExtractionError.noAudioTrack
        }

        if recordingURLs.count == 1 {
            try await exportAudio(
                from: AVURLAsset(url: firstURL),
                to: audioURL
            )
            return
        }

        let composition = AVMutableComposition()
        guard let destinationTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw AudioExtractionError.cannotCreateExporter
        }

        var insertionTime = CMTime.zero
        for recordingURL in recordingURLs {
            let asset = AVURLAsset(url: recordingURL)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let sourceTrack = audioTracks.first else { continue }
            let duration = try await asset.load(.duration)
            guard duration.isValid, duration > .zero else { continue }
            try destinationTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: sourceTrack,
                at: insertionTime
            )
            insertionTime = insertionTime + duration
        }

        guard insertionTime > .zero else {
            throw AudioExtractionError.noAudioTrack
        }
        try await exportAudio(from: composition, to: audioURL)
    }

    private static func exportAudio(
        from asset: AVAsset,
        to audioURL: URL
    ) async throws {
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw AudioExtractionError.noAudioTrack
        }

        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw AudioExtractionError.cannotCreateExporter
        }
        try? FileManager.default.removeItem(at: audioURL)
        try await exporter.export(to: audioURL, as: .m4a)
    }
}

enum AudioExtractionError: LocalizedError {
    case noAudioTrack
    case cannotCreateExporter

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            "The recording did not contain an audio track."
        case .cannotCreateExporter:
            "Nook could not prepare the meeting audio for transcription."
        }
    }
}
