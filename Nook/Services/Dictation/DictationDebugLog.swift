#if DEBUG
import Foundation

/// Appends dictation diagnostics to a file.
///
/// Dictation can only be exercised by actually holding the shortcut in another
/// app, and how the app was launched changes what macOS attributes its
/// permissions to — so a build being diagnosed has to be started the same way a
/// user starts it, with no terminal attached to read `print` from. A file works
/// either way.
///
/// Debug builds only. Nothing here ships.
enum DictationDebugLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/nook-dictation.log")

    static func write(_ message: String) {
        print(message)
        let stamp = Date().formatted(date: .omitted, time: .standard)
        guard let data = "\(stamp) \(message)\n".data(using: .utf8) else {
            return
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
#endif
