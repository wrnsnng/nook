import Darwin
import Foundation

/// A companion is eligible only after a completed writer publishes its receipt.
/// A playable but unfinished movie is not evidence that all captured audio made
/// it to disk. The original ScreenCaptureKit recording remains the fallback.
enum SourceAudioFiles {
    static func directory(for capture: URL) -> URL {
        capture.deletingPathExtension().appendingPathExtension("sources")
    }

    static func capture(for directory: URL) -> URL {
        directory.deletingLastPathComponent().appendingPathComponent(
            directory.deletingPathExtension().lastPathComponent + ".mp4", isDirectory: false
        )
    }

    static func audio(in directory: URL) -> URL { directory.appendingPathComponent("audio.mov") }

    static func byteSize(of artifact: URL) -> Int64 {
        if artifact.pathExtension == "sources", isDirectoryWithoutSymlink(artifact) {
            return [audio(in: artifact), artifact.appendingPathComponent("complete.json")]
                .reduce(0) { total, file in
                    let size = (try? FileIdentity.read(file).size) ?? 0
                    let sum = total.addingReportingOverflow(max(0, size))
                    return sum.overflow ? .max : sum.partialValue
                }
        }
        return (try? FileIdentity.read(artifact).size) ?? 0
    }

    struct Selection {
        let urls: [URL]
        let snapshots: [NoteCombiner.AudioFileSnapshot]

        func validate() throws {
            do { for snapshot in snapshots { try snapshot.validate() } }
            catch { throw AudioExtractionError.filesChanged }
        }
    }

    static func select(_ captures: [URL]) throws -> Selection {
        var urls: [URL] = []
        var snapshots: [NoteCombiner.AudioFileSnapshot] = []
        for capture in captures {
            snapshots.append(try NoteCombiner.AudioFileSnapshot(url: capture))
            if capture.pathExtension.lowercased() == "mp4", let companion = completedAudio(for: capture) {
                let receipt = directory(for: capture).appendingPathComponent("complete.json")
                snapshots.append(try NoteCombiner.AudioFileSnapshot(url: receipt))
                snapshots.append(try NoteCombiner.AudioFileSnapshot(url: companion))
                // Close the read-to-snapshot window before accepting a receipt.
                guard completedAudio(for: capture) == companion else { throw AudioExtractionError.filesChanged }
                urls.append(companion)
            } else { urls.append(capture) }
        }
        return Selection(urls: urls, snapshots: snapshots)
    }

    static func completedAudio(for capture: URL) -> URL? {
        let directory = directory(for: capture)
        let receiptURL = directory.appendingPathComponent("complete.json")
        let audioURL = audio(in: directory)
        guard isDirectoryWithoutSymlink(directory),
              let receiptIdentity = try? FileIdentity.read(receiptURL),
              receiptIdentity.size > 0, receiptIdentity.size < 65_536,
              let data = try? Data(contentsOf: receiptURL),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.version == 1, receipt.captureName == capture.lastPathComponent,
              (try? FileIdentity.read(audioURL)) == receipt.audio,
              (try? FileIdentity.read(receiptURL)) == receiptIdentity else { return nil }
        // If the original was removed externally, the completed companion is
        // still recoverable. An existing but changed original rejects the old
        // companion instead of silently substituting an earlier conversation.
        var info = stat()
        if lstat(capture.path, &info) == 0 {
            guard let original = receipt.capture, (try? FileIdentity.read(capture)) == original else { return nil }
        } else if errno != ENOENT { return nil }
        return audioURL
    }

    static func publishCompletion(for capture: URL) throws {
        let directory = directory(for: capture)
        guard isDirectoryWithoutSymlink(directory) else { throw AudioExtractionError.filesChanged }
        let audioIdentity = try FileIdentity.read(audio(in: directory))
        guard audioIdentity.size > 0 else { throw AudioExtractionError.invalidExport }
        let receipt = Receipt(version: 1, captureName: capture.lastPathComponent,
                              capture: try optionalIdentity(capture), audio: audioIdentity)
        let url = directory.appendingPathComponent("complete.json")
        try NoteCombiner.AudioFileSnapshot.requireAbsence(at: url)
        try JSONEncoder().encode(receipt).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func optionalIdentity(_ url: URL) throws -> FileIdentity? {
        var info = stat()
        if lstat(url.path, &info) != 0, errno == ENOENT { return nil }
        return try FileIdentity.read(url)
    }

    private static func isDirectoryWithoutSymlink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    private struct Receipt: Codable {
        let version: Int
        let captureName: String
        let capture: FileIdentity?
        let audio: FileIdentity
    }

    /// Local ownership checks, not authenticated provenance. Copying/replacing
    /// these files invalidates the receipt. Portable source labels live in the
    /// saved Markdown; temporary recovery packages are not a transport format.
    private struct FileIdentity: Codable, Equatable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        static func read(_ url: URL) throws -> Self {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                throw AudioExtractionError.filesChanged
            }
            return Self(device: Int64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size),
                        modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec,
                        changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec)
        }
    }
}
