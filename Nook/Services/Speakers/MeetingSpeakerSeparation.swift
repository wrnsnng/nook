import AVFoundation
import Foundation

/// Whether Nook tells the meeting-side voices apart after a recording. On
/// unless the user turns it off in Settings, Listening.
enum SpeakerSeparationPreference {
    static let key = "separateSpeakers"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}

/// Labels the meeting side of a finished recording's transcript with the
/// voices that spoke it, before the note is first written.
///
/// It runs while the recording still exists: with audio retention off the
/// capture files are removed as soon as the note is saved. It is also strictly
/// best effort. Anything that stops it (no labelled system track, the models,
/// the audio) leaves the transcript exactly as it was, "Meeting" and all; a
/// meeting is never lost or delayed into failure over who said what.
enum MeetingSpeakerSeparation {
    static func labelled(
        _ transcript: [TranscriptSegment],
        recordingURLs: [URL],
        service: SpeakerDiarizationService = SpeakerDiarizationService(),
        isEnabled: Bool = SpeakerSeparationPreference.isEnabled()
    ) async -> [TranscriptSegment] {
        guard
            isEnabled,
            service.modelsAvailable,
            transcript.contains(where: { $0.source == .system })
        else {
            return transcript
        }

        let directory: URL
        do {
            directory = try FileManager.default.url(
                for: .itemReplacementDirectory, in: .userDomainMask,
                appropriateFor: FileManager.default.temporaryDirectory, create: true
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path
            )
        } catch {
            return transcript
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let selection = try SourceAudioFiles.select(recordingURLs)
            let meetingSide = directory.appendingPathComponent("meeting-side.m4a")
            guard try await MeetingSideAudio.export(
                from: selection.urls, to: meetingSide
            ) else {
                // No capture carried a labelled system track (older
                // recordings, or ones whose source package did not
                // complete). A mixed recording would separate the user's own
                // voice as a speaker, so nothing is labelled.
                return transcript
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: meetingSide.path
            )
            let turns = try await service.diarize(audioURL: meetingSide)
            let assignments = SpeakerAttribution.renumberedByFirstAppearance(
                SpeakerAttribution.assign(segments: transcript, turns: turns, audio: .systemTrack),
                in: transcript
            )
            return SpeakerNames.apply(assignments, to: transcript)
        } catch {
            return transcript
        }
    }
}

/// The meeting side of a recording as one audio file on the note's timeline.
///
/// Every system-labelled track of every captured part is placed at the offset
/// its part starts at, so one separation pass covers the whole meeting and a
/// voice keeps the same number across pauses. Part offsets follow
/// `RecordedSourceTranscription`, which built the transcript's timeline.
enum MeetingSideAudio {
    /// Returns false when no part carries a labelled system track.
    static func export(from recordingURLs: [URL], to destination: URL) async throws -> Bool {
        let composition = AVMutableComposition()
        guard let output = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw AudioExtractionError.cannotCreateExporter
        }

        var assets: [AVURLAsset] = []
        defer { withExtendedLifetime(assets) {} }
        var partStart = 0.0
        var inserted = false
        for url in recordingURLs {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: url)
            assets.append(asset)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let duration = try await asset.load(.duration)
            guard duration.isNumeric, duration.seconds.isFinite, duration > .zero else {
                throw AudioExtractionError.invalidTimeline
            }
            var partDuration = duration.seconds
            for track in tracks {
                let range = try await track.load(.timeRange)
                guard range.isValid, range.start.isNumeric, range.duration.isNumeric,
                      range.start.seconds.isFinite, range.end.seconds.isFinite,
                      range.duration > .zero else {
                    throw AudioExtractionError.invalidTimeline
                }
                partDuration = max(partDuration, range.end.seconds)
                let source = try await RecordedAudioSource.source(in: try await track.load(.metadata))
                guard source == .system else { continue }
                try output.insertTimeRange(
                    range,
                    of: track,
                    at: CMTime(seconds: partStart + range.start.seconds, preferredTimescale: 48_000)
                )
                inserted = true
            }
            partStart += partDuration
        }
        guard inserted else { return false }

        guard let exporter = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw AudioExtractionError.cannotCreateExporter
        }
        try await exporter.export(to: destination, as: .m4a)
        try Task.checkCancellation()
        return true
    }
}
