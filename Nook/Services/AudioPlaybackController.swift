import AVFoundation

/// Plays kept meeting audio and reports the position for transcript sync.
///
/// Kept audio belongs to the note's immutable identifier inside its library's
/// recordings folder. A renamed note keeps the same recording, and a note
/// whose earlier audio was discarded maps playback through `audioStart`.
@MainActor
final class AudioPlaybackController: NSObject, ObservableObject,
    AVAudioPlayerDelegate {
    /// The offset currently playing, so the transcript can follow along.
    @Published private(set) var activeOffset: TimeInterval?
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var lastError: String?

    private var player: AVAudioPlayer?
    private var playingURL: URL?

    /// Whether kept audio exists for a note, without starting anything.
    static func audioURL(for note: MeetingNote) -> URL? {
        guard let fileURL = note.fileURL else { return nil }
        let candidate = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".recordings", isDirectory: true)
            .appendingPathComponent("\(note.id.uuidString).m4a")
        let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true
            && FileManager.default.isReadableFile(atPath: candidate.path)
            ? candidate
            : nil
    }

    /// An earlier sitting without retained audio must not play an unrelated
    /// passage from the start of the remaining recording.
    static func audioOffset(
        for transcriptOffset: TimeInterval,
        in note: MeetingNote
    ) -> TimeInterval? {
        guard transcriptOffset.isFinite, note.audioStart.isFinite,
              note.audioStart >= 0, transcriptOffset >= note.audioStart
        else { return nil }
        return transcriptOffset - note.audioStart
    }

    static func transcriptOffset(
        for audioOffset: TimeInterval,
        in note: MeetingNote
    ) -> TimeInterval? {
        guard audioOffset.isFinite, audioOffset >= 0,
              note.audioStart.isFinite, note.audioStart >= 0
        else { return nil }
        let offset = note.audioStart + audioOffset
        return offset.isFinite ? offset : nil
    }

    func toggle(url: URL, at offset: TimeInterval) {
        if isPlaying, playingURL == url {
            stop()
            return
        }
        start(url: url, at: offset)
    }

    func start(url: URL, at offset: TimeInterval) {
        stop()

        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            lastError = "Nook couldn’t open the kept recording."
            return
        }
        guard offset.isFinite, offset >= 0, offset < player.duration else {
            // A merge can retain only some sittings. Clamping an unavailable
            // passage to the end would play different words as its evidence.
            lastError = "No kept audio is available for this passage."
            return
        }
        self.player = player
        playingURL = url
        duration = player.duration
        player.currentTime = offset
        player.delegate = self
        guard player.play() else {
            stop()
            lastError = "Nook couldn’t start audio playback. Try again."
            return
        }
        isPlaying = true
        activeOffset = player.currentTime
    }

    /// Advances the published position; called by the view's tick.
    func refreshPosition() {
        guard let player, isPlaying else { return }
        activeOffset = player.currentTime
    }

    func stop() {
        player?.stop()
        player = nil
        playingURL = nil
        isPlaying = false
        activeOffset = nil
        lastError = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        let completedPlayer = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let current = self.player,
                  ObjectIdentifier(current) == completedPlayer
            else { return }
            self.stop()
        }
    }
}
