import Foundation

/// A small local journal of operational state changes.
///
/// Entries are chosen from a fixed enum, so meeting titles, dictated words,
/// paths, errors, and transcript content cannot enter a release diagnostic by
/// accident. The journal never leaves the Mac and is bounded so a long-running
/// menu-bar process cannot grow it indefinitely.
@MainActor
enum NookEventLog {
    enum Event: String {
        case captureStarted = "capture.started"
        case captureRecoveredAfterUnexpectedStop = "capture.recovered-after-unexpected-stop"
        case captureStopped = "capture.stopped"
        case captureStoppedUnexpectedly = "capture.stopped-unexpectedly"
        case capturePauseFinalizationUnconfirmed = "capture.pause-finalization-unconfirmed"
        case dictationFailed = "dictation.failed"
        // Adopting a session recording renamed the note's old audio aside and
        // then could neither move the new file in nor put the old one back.
        case keptAudioStranded = "audio.kept-stranded"
        case dictationFinished = "dictation.finished"
        case dictationStarted = "dictation.started"
        case meetingProcessingFailed = "meeting.processing-failed"
        case meetingSaved = "meeting.saved"
        case meetingSavedFromLiveCaptions = "meeting.saved-from-live-captions"
        case meetingStopDeferred = "meeting.stop-deferred"
        case meetingStopStarted = "meeting.stop-started"
        case summaryGenerated = "summary.generated"
        case summaryGenerationFailed = "summary.generation-failed"
        case summaryModelUnavailable = "summary.model-unavailable"
        // A summary that failed used to journal one line for every cause, so
        // a diagnostic could not tell "Apple Intelligence is off" from "the
        // transcript did not fit" or "the model refused".
        case summaryContextExceeded = "summary.context-exceeded"
        case summaryDeclined = "summary.declined"
        case summaryDeviceNotEligible = "summary.device-not-eligible"
        case summaryIntelligenceDisabled = "summary.intelligence-disabled"
        case summaryLanguageUnsupported = "summary.language-unsupported"
        case summaryModelBusy = "summary.model-busy"
        case summaryModelNotReady = "summary.model-not-ready"
        case summaryRejectedAsUngrounded = "summary.rejected-as-ungrounded"
        case summaryTimedOut = "summary.timed-out"
    }

    private static let maximumBytes = 512 * 1_024
    static let url: URL = {
        let identity = Bundle.main.bundleIdentifier?
            .replacingOccurrences(of: ".", with: "-") ?? "unknown"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/nook-events-\(identity).log")
    }()

    static func write(_ event: Event) {
        let manager = FileManager.default
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size >= maximumBytes {
            try? manager.removeItem(at: url)
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(event.rawValue)\n".data(using: .utf8) else {
            return
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}

#if DEBUG

/// Appends diagnostics to a file.
///
/// Dictation can only be exercised by actually holding the shortcut in another
/// app, and how the app was launched changes what macOS attributes its
/// permissions to — so a build being diagnosed has to be started the same way a
/// user starts it, with no terminal attached to read `print` from. A file works
/// either way.
///
/// Debug builds only. Nothing here ships.
enum NookDebugLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/nook-debug.log")

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
