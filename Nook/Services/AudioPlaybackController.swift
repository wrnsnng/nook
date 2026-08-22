import AVFoundation

/// Plays kept meeting audio and reports the position for transcript sync.
///
/// Playback only ever points at audio Nook extracted itself, next to the
/// note. The transcript timeline is expected to line up with the extracted
/// file because both freeze while a recording is paused: live ingestion stops
/// during a pause, and extraction concatenates the per-segment recordings in
/// order.
@MainActor
final class AudioPlaybackController: NSObject, ObservableObject,
    AVAudioPlayerDelegate {
    /// The offset currently playing, so the transcript can follow along.
    @Published private(set) var activeOffset: TimeInterval?
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var playingURL: URL?

    /// Whether kept audio exists for a note, without starting anything.
    static func audioURL(for note: MeetingNote) -> URL? {
        guard let fileURL = note.fileURL else { return nil }
        let candidate = fileURL.deletingPathExtension()
            .appendingPathExtension("m4a")
        return FileManager.default.fileExists(atPath: candidate.path)
            ? candidate
            : nil
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
            activeOffset = nil
            return
        }
        self.player = player
        playingURL = url
        duration = player.duration
        // A flag near the very end should still land inside the file.
        player.currentTime = min(max(0, offset), max(0, player.duration - 0.2))
        player.delegate = self
        player.play()
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
    }

    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        Task { @MainActor [weak self] in
            self?.stop()
        }
    }
}
