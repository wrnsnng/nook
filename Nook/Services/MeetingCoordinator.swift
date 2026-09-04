import AppKit
import AVFoundation
import Foundation

enum MeetingPhase: Equatable, Sendable {
    case idle
    case detected(DetectedMeeting)
    case recording(title: String, startedAt: Date)
    case processing(ProcessingStep)
    case completed(String)
    case failed(String)

    enum ProcessingStep: String, Sendable {
        case preparing = "Gathering the recording"
        case refining = "Refining the transcript"
        case transcribing = "Listening back locally"
        case summarizing = "Distilling the conversation"
        case saving = "Tucking away your notes"
        case discarding = "Discarding the recording"

        /// The one sentence shown for a processing step, wherever it appears.
        ///
        /// The panel and the live workspace used to word these independently
        /// and drift apart; both now read from here.
        var displaySentence: String {
            switch self {
            case .preparing:
                "Securing the recording before Nook shapes it into notes."
            case .refining:
                "Cleaning up the live captions while preserving what was actually said."
            case .transcribing:
                "Giving the saved audio a careful second listen, entirely on this Mac."
            case .summarizing:
                "Finding the useful shape of the conversation: themes, decisions, and next steps."
            case .saving:
                "Writing a durable Markdown note you can read with any editor."
            case .discarding:
                "Removing the accidental recording without creating a note."
            }
        }
    }

    var menuBarSymbol: String {
        switch self {
        case .recording:
            "record.circle.fill"
        case .processing:
            "ellipsis.circle"
        case .detected:
            "sparkle.magnifyingglass"
        case .failed:
            "exclamationmark.circle"
        default:
            "quote.bubble"
        }
    }

    var isRecording: Bool {
        if case .recording = self { true } else { false }
    }
}

enum MeetingPanelMode: String, CaseIterable, Identifiable, Sendable {
    case transcript
    case summary
    case notes

    var id: Self { self }

    var label: String {
        switch self {
        case .transcript: "Transcript"
        case .summary: "Summary"
        case .notes: "My notes"
        }
    }

    var symbol: String {
        switch self {
        case .transcript: "captions.bubble"
        case .summary: "text.page.badge.magnifyingglass"
        case .notes: "square.and.pencil"
        }
    }
}

enum MeetingTerminationState: Equatable, Sendable {
    case inactive
    case recording
    case processing
}

/// One part of a long summary, out of the parts in the current round.
/// Audio that could not be put back after a failed adoption.
///
/// Adopting a session recording renames the note's old audio out of the way
/// before moving the new file in. When the move in fails and the rename cannot
/// be undone, the recording is intact but no longer where the note points.
/// Carrying the path in the error is what lets the caller keep the cleanup
/// pass off it and, when nothing else will list it, name it to the user.
struct KeptAudioStranded: Error {
    /// Where the note's earlier audio actually ended up.
    let strandedURL: URL
    /// Whether that name is one the recovery scan lists. When it is, Settings
    /// offers the recording back and the user is not sent looking for a file.
    let isListedByRecoveryScan: Bool
    let underlying: any Error
}

/// A transcript-first save once existed, but Nook can no longer verify a note
/// file that owns those words. Recovery must keep the recording in this case;
/// manufacturing a second note would undo an explicit deletion or overwrite
/// an external file operation.
private struct DurableMeetingNoteUnavailable: LocalizedError {
    let reason: String

    var errorDescription: String? { reason }
}

struct SummaryProgress: Equatable, Sendable {
    let part: Int
    let total: Int
}

/// The coordinator's fast-moving outputs, split into their own object so
/// that observers of `MeetingCoordinator` do not pay for them.
///
/// `audioLevel` publishes up to ~12 times a second and `liveTranscript` up to
/// ~10 while anyone speaks; `elapsed` once a second. Combine's
/// `objectWillChange` does not say which property changed, so while these
/// lived on the coordinator every view holding it re-rendered on every tick,
/// including the whole Library window (1.19.0 and 1.20.0 spent most of a
/// recording re-laying that window out). Only the small views that actually
/// draw a level, a caption or a clock should observe this object, through
/// `@ObservedObject var live: MeetingLiveSignals` fed with `meeting.live`.
/// Reading `meeting.audioLevel` and friends on the coordinator still works
/// for non-view code, but does not subscribe a view to changes.
@MainActor
final class MeetingLiveSignals: ObservableObject {
    @Published fileprivate(set) var audioLevel = 0.0
    @Published fileprivate(set) var elapsed: TimeInterval = 0
    @Published fileprivate(set) var liveTranscript = LiveTranscriptState.empty
}

@MainActor
final class MeetingCoordinator: ObservableObject {
    @Published private(set) var phase: MeetingPhase = .idle
    /// Fast-changing outputs; see `MeetingLiveSignals`. Views draw from this.
    let live = MeetingLiveSignals()
    /// Non-observing conveniences for the coordinator's own logic, tests and
    /// previews. A SwiftUI body reading these will NOT update when they change;
    /// observe `live` instead.
    var audioLevel: Double { live.audioLevel }
    var elapsed: TimeInterval { live.elapsed }
    var liveTranscript: LiveTranscriptState { live.liveTranscript }
    @Published private(set) var liveInsights: MeetingInsights?
    @Published private(set) var liveSummaryIsRefreshing = false
    @Published private(set) var liveSummaryUpdatedAt: Date?
    /// How far the final summary has got through a long transcript, while it
    /// is being condensed in parts.
    @Published private(set) var summaryProgress: SummaryProgress?
    /// The meeting currently being recorded or processed, named by the
    /// identifier its recording files carry.
    ///
    /// The recovery list offers recordings that belong to no saved note, and
    /// an in-flight recording matches that description for its whole life.
    /// Publishing the identifier lets that list leave it alone rather than
    /// inviting somebody to recover a meeting still being written.
    @Published private(set) var activeRecordingID: UUID?
    /// Notes typed by hand while the meeting runs.
    ///
    /// Mirrored to a file beside the recording as it changes. They used to
    /// exist only here, so a crash, a force quit, or a flat battery during a
    /// meeting took every word of them: recovering the recording afterwards
    /// rebuilt the transcript and the summary and silently dropped the one
    /// part the user had written themselves.
    @Published var liveNotes = "" {
        didSet {
            guard !liveNotes.utf8.elementsEqual(oldValue.utf8) else { return }
            scheduleLiveNotesSave()
        }
    }
    @Published private(set) var liveNotesDetached = false
    /// Moments flagged during the live recording, in flag order.
    @Published private(set) var liveMoments: [MeetingMoment] = []
    /// Set briefly after a flag so the panel can acknowledge it without a
    /// dialog; cleared on its own timer.
    @Published private(set) var momentAcknowledgedAt: Date?
    @Published private(set) var isPaused = false
    @Published private(set) var pauseTransitionInFlight = false
    @Published private(set) var liveCaptionNotice: String?
    @Published private(set) var requiredPermission: NookPermission?
    @Published private(set) var topPanelHidden = false
    @Published var localeIdentifier: String {
        didSet { UserDefaults.standard.set(localeIdentifier, forKey: "transcriptionLocale") }
    }
    @Published var keepAudio: Bool {
        didSet {
            UserDefaults.standard.set(keepAudio, forKey: Self.keepAudioKey)
        }
    }

    nonisolated static let keepAudioKey = "keepAudio"

    /// The audio-retention setting, readable without a coordinator.
    ///
    /// Recovery finishes a meeting this coordinator never got to, and it has
    /// to answer the same question about the extracted audio: with retention
    /// on, the `.m4a` is the note's kept audio, not a temporary file.
    nonisolated static var keepAudioPreference: Bool {
        UserDefaults.standard.bool(forKey: keepAudioKey)
    }
    @Published var showLiveCaptions: Bool {
        didSet { UserDefaults.standard.set(showLiveCaptions, forKey: "showLiveCaptions") }
    }
    @Published var panelMode: MeetingPanelMode {
        didSet { UserDefaults.standard.set(panelMode.rawValue, forKey: "meetingPanelMode") }
    }

    var onPresentationRequested: (() -> Void)?
    var onPanelInteractionRequested: (() -> Void)?
    var onMeetingNotificationRequested: ((DetectedMeeting) -> Void)?
    var onRecordingStopped: (() -> Void)?
    var onPanelDismissRequested: (() -> Void)?

    private let store: MarkdownStore
    private let detector: MeetingDetector
    /// The input check shares the microphone and ScreenCaptureKit. Waiting for
    /// its teardown before requesting meeting capture prevents two starts from
    /// opening those resources during the same turn of the main actor.
    private let prepareForAudioCapture: (@MainActor () async throws -> Void)?
    private let capture = CaptureService()
    /// Global flag hotkey, registered only while a recording is running.
    private let momentHotKeys = MomentHotKeyController(
        shortcut: ShortcutStore.shared.binding(for: .flagMoment)
    )
    private let transcriber = TranscriptionService()
    private let liveTranscriber = LiveTranscriptionService()
    private let summarizer = SummaryService()
    /// Every path that starts, finishes, fails, or discards a meeting already
    /// assigns this. Deriving the published identifier here rather than at
    /// each of those sites is what keeps the two from drifting apart.
    private var activeDraft: MeetingDraft? {
        didSet {
            if oldValue?.id != activeDraft?.id
                || oldValue?.recordingURL != activeDraft?.recordingURL {
                // A queued write belongs to the captured recording, including
                // when a failed start is replaced by another session. It must
                // not land after that owner's artifacts have been removed.
                liveNotesSaveTask?.cancel()
                liveNotesSaveTask = nil
            }
            guard activeRecordingID != activeDraft?.id else { return }
            activeRecordingID = activeDraft?.id
            if activeDraft == nil {
                activeAttachmentIdentity = nil
            }
        }
    }
    /// Kept independently of the capture format. A copied UUID or changed
    /// notes folder cannot take ownership while an audio/model await runs.
    private var activeAttachmentIdentity: LibraryNoteIdentity?
    private var liveNotesSaveTask: Task<Void, Never>?
    private var elapsedTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var recordingStartTask: Task<Void, Never>?
    private var liveStartupTask: Task<Void, Never>?
    private var liveSummaryTask: Task<Void, Never>?
    /// Progress callbacks can arrive after a model deadline because the
    /// underlying framework may not observe task cancellation immediately.
    /// A generation makes those late callbacks harmless when a meeting has
    /// moved on, been discarded, or started another summary pass.
    private var summaryProgressGeneration = 0
    /// Background enrichment for an appended sitting. The sitting itself is
    /// saved and its audio settled before this starts, so the note is useful
    /// without waiting on a model. A token prevents a cancelled older pass
    /// from applying after a newer append to the same note.
    private var appendedSummaryTasks: [UUID: Task<Void, Never>] = [:]
    private var appendedSummaryTokens: [UUID: UUID] = [:]
    private var pauseTask: Task<Void, Never>?
    private var momentNoticeTask: Task<Void, Never>?
    private var dismissedDetection: DetectedMeeting?
    private var targetAudioLevel = 0.0
    private var liveTranscriptIsComplete = false
    private var lastSummarizedSegmentCount = 0
    private var lastSummaryAt = Date.distantPast
    /// A refresh the user asked for. Held rather than acted on immediately so
    /// it survives until the pass already running finishes.
    private var liveSummaryForceRequested = false
    private var lastStallCheckAt = Date.distantPast
    private var pendingStartRequest: PendingStartRequest?
    private var accumulatedElapsed: TimeInterval = 0
    private var activeElapsedStartedAt: Date?
    private var processingCancellationRequested = false
    /// Once an appended sitting is durable, cancelling would have to roll the
    /// old note back while preserving edits made since the append. Closing the
    /// cancellation window at that synchronous save boundary avoids either
    /// deleting the existing note or silently keeping a half-discarded sitting.
    private var processingOwnsAttachedScaffold = false
    /// A meeting can end while ScreenCaptureKit is finalizing a pause or adding
    /// the resumed output. Remember that stop request and run it as soon as the
    /// transition becomes terminal instead of silently discarding it.
    private var stopRequestedDuringPauseTransition = false

    init(
        store: MarkdownStore,
        detector: MeetingDetector,
        prepareForAudioCapture: (@MainActor () async throws -> Void)? = nil
    ) {
        self.store = store
        self.detector = detector
        self.prepareForAudioCapture = prepareForAudioCapture
        self.localeIdentifier = UserDefaults.standard.string(forKey: "transcriptionLocale")
            ?? Locale.current.identifier
        self.keepAudio = Self.keepAudioPreference
        self.showLiveCaptions = UserDefaults.standard.object(forKey: "showLiveCaptions") as? Bool
            ?? true
        let storedPanelMode = UserDefaults.standard.string(forKey: "meetingPanelMode")
        self.panelMode = MeetingPanelMode(rawValue: storedPanelMode ?? "") ?? .transcript

        detector.onMeetingStarted = { [weak self] detection in
            self?.handleDetection(detection)
        }
        detector.onMeetingEnded = { [weak self] in
            self?.handleMeetingEnded()
        }
        liveTranscriber.onUpdate = { [weak self] state in
            self?.receiveLiveTranscript(state)
        }
        liveTranscriber.onRecoverableError = { [weak self] message in
            self?.liveCaptionNotice = message
            self?.liveTranscriptIsComplete = false
        }
        capture.onUnexpectedStop = { [weak self] _ in
            self?.finishAfterCaptureStopped()
        }
        momentHotKeys.onFlag = { [weak self] in
            self?.flagMoment()
        }
    }

    func startDetectedMeeting() {
        guard case .detected(let detection) = phase else { return }
        startRecording(title: detection.suggestedTitle, sourceApp: detection.appName)
    }

    func startManualMeeting() {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE h:mm a"
        startRecording(
            title: "Meeting \(formatter.string(from: Date()))",
            sourceApp: "Manual"
        )
    }

    /// Starts a recording that will be appended to an existing note when it
    /// finishes, rather than creating a new one.
    ///
    /// Entirely user-initiated from the note's own actions; Nook never
    /// suggests growing one note versus starting another. A spoken note is a
    /// valid target and becomes a meeting note on finish, its prose kept as
    /// personal notes. Digests are compiled, not recorded, so they are not
    /// appendable.
    func continueRecording(into note: MeetingNote) {
        guard activeDraft == nil, processingTask == nil else { return }
        guard note.kind != .digest else { return }
        guard Self.attachedRecordingTarget(
            expected: note.libraryIdentity, notes: store.notes, libraryURL: store.storageURL
        ) != nil else {
            refuseUnavailableAttachment()
            return
        }
        startRecording(
            title: note.title,
            sourceApp: note.sourceApp,
            attaching: note.libraryIdentity
        )
    }

    /// Pure ownership policy shared by initial continuation, permission
    /// retries, and processing after suspension. A UUID-only match is unsafe
    /// even when one of the copies happens to be first in the library.
    static func attachedRecordingTarget(
        expected: LibraryNoteIdentity,
        notes: [MeetingNote],
        libraryURL: URL
    ) -> MeetingNote? {
        guard let file = expected.fileURL,
              file.deletingLastPathComponent().standardizedFileURL == libraryURL.standardizedFileURL,
              LibraryNoteResolution.resolve(expected.noteID, in: notes) == .unique(expected),
              let target = notes.first(where: { $0.libraryIdentity == expected }),
              target.kind != .digest else { return nil }
        return target
    }

    /// Legacy restart requests without a path do not identify a destination.
    static func pendingAttachmentIdentity(noteID: String, filePath: String?) -> LibraryNoteIdentity? {
        guard let id = UUID(uuidString: noteID), let filePath,
              filePath.hasPrefix("/"), !filePath.contains("\0") else { return nil }
        let url = URL(fileURLWithPath: filePath)
        guard url.standardizedFileURL.path == filePath else { return nil }
        return LibraryNoteIdentity(noteID: id, fileURL: url)
    }

    private static let unavailableAttachmentMessage =
        "The original note is missing, moved, or has a duplicate identity. Open the original note in its notes folder before recording into it again."

    private func refuseUnavailableAttachment() {
        pendingStartRequest = nil
        requiredPermission = nil
        phase = .failed(Self.unavailableAttachmentMessage)
        onPresentationRequested?()
    }

    private func requireAttachedTarget(for draft: MeetingDraft) throws -> MeetingNote {
        guard let attachment = activeAttachmentIdentity,
              draft.attachedNoteID == attachment.noteID,
              let target = Self.attachedRecordingTarget(
                  expected: attachment, notes: store.notes, libraryURL: store.storageURL
              ), let file = target.fileURL,
              FileManager.default.fileExists(atPath: file.path) else {
            throw DurableMeetingNoteUnavailable(reason: Self.unavailableAttachmentMessage)
        }
        return target
    }

    /// Closes out a meeting whose capture the system ended.
    ///
    /// The recording is over either way, so the choice is between saving what
    /// was captured and losing it. Everything up to that moment is real audio
    /// the user was relying on, so the meeting is finished normally and the
    /// reason is shown, rather than leaving a meeting that looks live and
    /// records nothing.
    private func finishAfterCaptureStopped() {
        guard phase.isRecording, processingTask == nil else { return }
        liveCaptionNotice = "Recording stopped early. Nook is saving what it captured."
        stopRecording()
    }

    func stopRecording() {
        guard phase.isRecording, processingTask == nil else {
            return
        }
        guard !pauseTransitionInFlight else {
            stopRequestedDuringPauseTransition = true
            NookEventLog.write(.meetingStopDeferred)
            return
        }
        stopRequestedDuringPauseTransition = false
        elapsedTask?.cancel()
        meterTask?.cancel()
        momentNoticeTask?.cancel()
        momentHotKeys.stop()
        onRecordingStopped?()
        topPanelHidden = false
        processingCancellationRequested = false
        processingOwnsAttachedScaffold = false
        phase = .processing(.preparing)
        NookEventLog.write(.meetingStopStarted)
        onPresentationRequested?()
        processingTask = Task { [weak self] in
            await self?.finishRecording()
        }
    }

    /// The sentence shown under the current processing step.
    ///
    /// Long meetings are condensed in parts, and several minutes of
    /// "Distilling the conversation" with nothing moving reads as a hang, so
    /// the part counter is appended here. Both the panel and the workspace
    /// read this one property, which is what keeps a step from being worded
    /// two ways.
    var processingDetail: String {
        guard case .processing(let step) = phase else { return "" }
        guard step == .summarizing, let summaryProgress else {
            return step.displaySentence
        }
        return step.displaySentence
            + " Working through part \(summaryProgress.part)"
            + " of \(summaryProgress.total)."
    }

    var terminationState: MeetingTerminationState {
        if phase.isRecording {
            return .recording
        }
        if case .processing = phase {
            return .processing
        }
        return activeDraft == nil ? .inactive : .processing
    }

    /// Finishes an active recording before application termination. A start
    /// that is still waiting on permissions is cancelled and discarded; a real
    /// recording is allowed to finish its local note pipeline.
    func prepareForApplicationTermination() async -> Bool {
        // Cleared again if the app ends up staying open. Leaving it set would
        // hold every later recording to the quit deadline, which is far shorter
        // than an interactive stop is allowed, and would reintroduce the
        // timeout that lost a meeting in the first place.
        isTerminating = true
        var willTerminate = false
        defer { isTerminating = willTerminate }
        if let pauseTask {
            await pauseTask.value
        }

        if let startTask = recordingStartTask {
            processingCancellationRequested = true
            startTask.cancel()
            await startTask.value
        }

        if phase.isRecording {
            stopRecording()
        }
        if let processingTask {
            await processingTask.value
        }

        guard activeDraft == nil,
              recordingStartTask == nil,
              processingTask == nil
        else {
            return false
        }
        if case .failed = phase {
            return false
        }
        willTerminate = true
        return true
    }

    /// A final draft-save decision can keep the app open after recording
    /// cleanup succeeded. Later meetings must regain their normal deadlines.
    func cancelApplicationTermination() {
        isTerminating = false
    }

    var canCancelProcessing: Bool {
        guard case .processing(let step) = phase,
              step != .discarding,
              activeDraft != nil,
              !processingOwnsAttachedScaffold
        else {
            return false
        }
        // The active draft is created before processing becomes visible, so
        // this remains stable even during the brief hand-off between capture
        // and the asynchronous processing task.
        return true
    }

    func cancelProcessing() {
        guard canCancelProcessing else { return }
        processingCancellationRequested = true
        topPanelHidden = false
        phase = .processing(.discarding)
        onPresentationRequested?()
        recordingStartTask?.cancel()
        processingTask?.cancel()
    }

    /// Asks before cancelling destroys the recording.
    ///
    /// Cancel during processing permanently deletes audio that captured fine,
    /// and the button sits next to transport controls people reach for while
    /// distracted. One confirmation with a reflex-safe default keeps a
    /// misclick meaningless instead of fatal.
    func requestProcessingCancellation() {
        guard canCancelProcessing else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard this meeting?"
        let transcriptFirstNoteExists = activeDraft.flatMap { draft in
            store.uniqueNote(id: draft.id)
        }?.fileURL.map { FileManager.default.fileExists(atPath: $0.path) }
            ?? false
        alert.informativeText = transcriptFirstNoteExists
            ? "Nook has already saved a transcript-first note. Discarding moves that note to the Trash and deletes the recording permanently."
            : "Processing has not saved a note yet. Discarding deletes the recording permanently."
        alert.addButton(withTitle: "Discard Recording")
        alert.addButton(withTitle: "Keep Processing")
        // The safe option takes Return, so reflexive agreement preserves the
        // recording rather than destroying it.
        alert.buttons.first?.hasDestructiveAction = true
        alert.buttons.first?.keyEquivalent = ""
        alert.buttons.last?.keyEquivalent = "\r"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        cancelProcessing()
    }

    func togglePause() {
        if isPaused {
            resumeRecording()
        } else {
            pauseRecording()
        }
    }

    /// Marks this instant of the meeting so it can be found in the note.
    ///
    /// Allowed while paused as well: the offset simply freezes with the
    /// elapsed clock, which is what the flag means.
    func flagMoment() {
        guard phase.isRecording else { return }
        let offset = Self.currentRecordingOffset(
            accumulated: accumulatedElapsed,
            startedAt: activeElapsedStartedAt,
            now: Date()
        )
        liveMoments = Self.appendingMoment(liveMoments, at: offset)
        if liveMoments.last?.offset == offset {
            momentAcknowledgedAt = Date()
            momentNoticeTask?.cancel()
            momentNoticeTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self?.momentAcknowledgedAt = nil
            }
        }
    }

    /// Appends a flag unless it lands within a second of the previous one,
    /// which reads as a double-press rather than intent.
    static func appendingMoment(
        _ moments: [MeetingMoment],
        at offset: TimeInterval
    ) -> [MeetingMoment] {
        if let last = moments.last?.offset, abs(offset - last) < 1 {
            return moments
        }
        return moments + [MeetingMoment(offset: offset)]
    }

    static func currentRecordingOffset(
        accumulated: TimeInterval,
        startedAt: Date?,
        now: Date
    ) -> TimeInterval {
        accumulated + (startedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    func pauseRecording() {
        guard phase.isRecording, !isPaused, !pauseTransitionInFlight else {
            return
        }
        pauseTransitionInFlight = true
        accumulatedElapsed = elapsed
        activeElapsedStartedAt = nil
        elapsedTask?.cancel()
        isPaused = true
        live.audioLevel = 0
        targetAudioLevel = 0

        pauseTask = Task { [weak self] in
            guard let self else { return }
            defer {
                completePauseTransition()
            }
            do {
                try await capture.pause(
                    finalizationTimeout: isTerminating
                        ? CaptureService.quitFinalizationTimeout
                        : nil
                )
                liveCaptionNotice = "Paused. Nook is not saving or transcribing audio."
            } catch {
                isPaused = false
                activeElapsedStartedAt = Date()
                startElapsedClock()
                liveCaptionNotice = "Nook couldn’t pause this recording. Capture is still active."
            }
        }
    }

    func resumeRecording() {
        guard phase.isRecording, isPaused, !pauseTransitionInFlight else {
            return
        }
        pauseTransitionInFlight = true
        pauseTask = Task { [weak self] in
            guard let self else { return }
            defer {
                completePauseTransition()
            }
            do {
                try capture.resume()
                isPaused = false
                activeElapsedStartedAt = Date()
                startElapsedClock()
                liveCaptionNotice = nil
            } catch {
                liveCaptionNotice = "Nook couldn’t resume yet. Your completed audio remains safe."
            }
        }
    }

    func dismissPrompt() {
        if case .detected(let detection) = phase {
            dismissedDetection = detection
        }
        phase = .idle
    }

    func resetStatus() {
        guard !phase.isRecording else { return }
        requiredPermission = nil
        pendingStartRequest = nil
        phase = .idle
    }

    func selectPanelMode(_ mode: MeetingPanelMode) {
        panelMode = mode
        expandTopPanel()
        if mode == .summary {
            refreshLiveSummary()
        } else if mode == .notes {
            onPanelInteractionRequested?()
        }
    }

    func expandTopPanel() {
        guard phase.isRecording else { return }
        topPanelHidden = false
        showLiveCaptions = true
        onPresentationRequested?()
    }

    func collapseTopPanel() {
        guard phase.isRecording else { return }
        topPanelHidden = false
        showLiveCaptions = false
        onPresentationRequested?()
    }

    func hideTopPanel() {
        guard phase.isRecording else { return }
        topPanelHidden = true
        onPanelDismissRequested?()
    }

    func restoreTopPanel() {
        guard phase.isRecording else { return }
        topPanelHidden = false
        onPresentationRequested?()
    }

    func setLiveNotesDetached(_ detached: Bool) {
        liveNotesDetached = detached
        if detached, panelMode == .notes {
            panelMode = .transcript
        }
    }

    func refreshLiveSummary() {
        scheduleLiveSummary(force: true)
    }

    /// Re-reads the flag-moment hotkey after a rebind in Settings, keeping
    /// the registration live when a meeting is already recording.
    func refreshMomentHotKey() {
        momentHotKeys.apply(
            ShortcutStore.shared.binding(for: .flagMoment)
        )
    }

    func revealPermissions() {
        let permission = requiredPermission ?? .screenRecording
        if let url = permission.settingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    func performPermissionPrimaryAction() {
        guard let requiredPermission else {
            resetStatus()
            return
        }

        if requiredPermission == .screenRecording {
            persistPendingStartRequest()
            restartApplication()
        } else {
            retryPendingStartRequest()
        }
    }

    static func pendingStartNeedsLibrary(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: PermissionResumeKey.shouldResume)
            && defaults.string(forKey: PermissionResumeKey.attachedNoteID) != nil
    }

    /// True means a pending request supplied the launch presentation, either
    /// by starting capture or explaining why its attachment must be reselected.
    @discardableResult
    func resumePendingStartAfterPermission(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.bool(forKey: PermissionResumeKey.shouldResume) else {
            return false
        }
        guard !store.isLoading || !Self.pendingStartNeedsLibrary(defaults: defaults) else {
            // A cold launch has no notes until its detached reload publishes.
            // Leave every key intact so that publication can resume the request.
            return false
        }

        let title = defaults.string(forKey: PermissionResumeKey.title)
        let sourceApp = defaults.string(forKey: PermissionResumeKey.sourceApp)
        let attachedNoteID = defaults.string(forKey: PermissionResumeKey.attachedNoteID)
        let attachedNotePath = defaults.string(forKey: PermissionResumeKey.attachedNotePath)
        defaults.removeObject(forKey: PermissionResumeKey.shouldResume)
        defaults.removeObject(forKey: PermissionResumeKey.title)
        defaults.removeObject(forKey: PermissionResumeKey.sourceApp)
        defaults.removeObject(forKey: PermissionResumeKey.attachedNoteID)
        defaults.removeObject(forKey: PermissionResumeKey.attachedNotePath)

        guard let title, let sourceApp else { return false }
        var attachment: LibraryNoteIdentity?
        if let attachedNoteID {
            guard let captured = Self.pendingAttachmentIdentity(
                noteID: attachedNoteID, filePath: attachedNotePath
            ), let target = Self.attachedRecordingTarget(
                expected: captured, notes: store.notes, libraryURL: store.storageURL
            ), let file = target.fileURL,
               FileManager.default.fileExists(atPath: file.path) else {
                // Older requests stored only a UUID. It cannot prove which
                // file the person chose, so require a fresh explicit choice.
                refuseUnavailableAttachment()
                return true
            }
            attachment = captured
        }
        startRecording(title: title, sourceApp: sourceApp, attaching: attachment)
        return true
    }

    func restartApplication() {
        let applicationURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        Task { [weak self] in
            do {
                _ = try await NSWorkspace.shared.openApplication(
                    at: applicationURL,
                    configuration: configuration
                )
                NSApp.terminate(nil)
            } catch {
                self?.phase = .failed(
                    "Nook couldn’t restart automatically. Quit Nook from its menu, then open it again."
                )
                self?.onPresentationRequested?()
            }
        }
    }

    /// Optional calendar context, owned by AppModel. When enabled and
    /// permitted, a nearby event names the detected meeting after what the
    /// calendar calls it rather than what the app's window title says.
    weak var calendarContext: CalendarContextService?

    private func handleDetection(_ detection: DetectedMeeting) {
        guard activeDraft == nil, processingTask == nil, dismissedDetection != detection else { return }
        var detection = detection
        if let context = calendarContext,
           let event = context.event(enrichingDetectionAt: Date()),
           !event.title.trimmingCharacters(in: .whitespaces).isEmpty {
            detection = DetectedMeeting(
                appName: detection.appName,
                windowTitle: event.title
            )
        }
        phase = .detected(detection)
        onPresentationRequested?()
        onMeetingNotificationRequested?(detection)
    }

    /// Starts a recording named by a calendar event the user was prompted
    /// about. Still user-initiated: the prompt never records on its own.
    func startCalendarMeeting(title: String) {
        startRecording(title: title, sourceApp: "Calendar")
    }

    private func handleMeetingEnded() {
        dismissedDetection = nil
        if phase.isRecording {
            stopRecording()
        } else if case .detected = phase {
            phase = .idle
        }
    }

    private func startRecording(
        title: String,
        sourceApp: String,
        attaching attachment: LibraryNoteIdentity? = nil
    ) {
        guard activeDraft == nil, processingTask == nil else { return }
        if let attachment {
            guard let target = Self.attachedRecordingTarget(
                expected: attachment, notes: store.notes, libraryURL: store.storageURL
            ), let file = target.fileURL,
               FileManager.default.fileExists(atPath: file.path) else {
                refuseUnavailableAttachment()
                return
            }
        }
        pendingStartRequest = PendingStartRequest(
            title: title,
            sourceApp: sourceApp,
            attachment: attachment
        )
        activeAttachmentIdentity = attachment
        let attachedNoteID = attachment?.noteID
        requiredPermission = nil
        let id = UUID()
        let url = store.recordingsDirectory().appendingPathComponent("\(id.uuidString).mp4")
        let draft = MeetingDraft(
            id: id,
            title: title,
            sourceApp: sourceApp,
            startedAt: Date(),
            recordingURL: url,
            attachedNoteID: attachedNoteID
        )
        activeDraft = draft
        live.liveTranscript = .empty
        liveInsights = nil
        liveSummaryUpdatedAt = nil
        liveSummaryIsRefreshing = false
        liveNotes = ""
        lastSummarizedSegmentCount = 0
        lastSummaryAt = .distantPast
        liveSummaryForceRequested = false
        lastStallCheckAt = .distantPast
        invalidateSummaryProgress()
        liveCaptionNotice = nil
        liveTranscriptIsComplete = false
        isPaused = false
        pauseTransitionInFlight = false
        topPanelHidden = false
        processingCancellationRequested = false
        processingOwnsAttachedScaffold = false
        stopRequestedDuringPauseTransition = false
        accumulatedElapsed = 0
        activeElapsedStartedAt = nil
        live.audioLevel = 0
        targetAudioLevel = 0
        phase = .processing(.preparing)
        onPresentationRequested?()

        recordingStartTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await self.prepareForAudioCapture?()
                try Task.checkCancellation()
                guard self.activeDraft?.id == draft.id else { return }
                try await capture.requestPermissions()
                try Task.checkCancellation()
                try await SpeechAssets.requestAuthorization()
                try Task.checkCancellation()
                if draft.attachedNoteID != nil {
                    _ = try requireAttachedTarget(for: draft)
                }
                try await capture.start(
                    to: url,
                    permissionsAreReady: true
                )
                try Task.checkCancellation()
                recordingStartTask = nil
                pendingStartRequest = nil
                requiredPermission = nil
                phase = .recording(title: title, startedAt: draft.startedAt)
                activeElapsedStartedAt = Date()
                liveMoments = []
                momentAcknowledgedAt = nil
                startElapsedClock()
                startAudioMeter()
                momentHotKeys.start()
                startLiveCaptions()
            } catch {
                if Task.isCancelled || processingCancellationRequested {
                    await discardCancelledMeeting(
                        draft: draft,
                        additionalURLs: []
                    )
                    return
                }
                recordingStartTask = nil
                activeDraft = nil
                let cleanupFailures = RecordingArtifactCleanup.removeArtifacts(
                    for: draft
                )
                requiredPermission = Self.permissionRequired(for: error)
                if requiredPermission == nil {
                    pendingStartRequest = nil
                }
                phase = .failed(
                    error.localizedDescription
                        + Self.cleanupNotice(for: cleanupFailures)
                )
                onPresentationRequested?()
            }
        }
    }

    private func retryPendingStartRequest() {
        guard let request = pendingStartRequest else {
            resetStatus()
            return
        }
        startRecording(
            title: request.title,
            sourceApp: request.sourceApp,
            attaching: request.attachment
        )
    }

    private func persistPendingStartRequest() {
        guard let request = pendingStartRequest else { return }
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: PermissionResumeKey.shouldResume)
        defaults.set(request.title, forKey: PermissionResumeKey.title)
        defaults.set(request.sourceApp, forKey: PermissionResumeKey.sourceApp)
        if let attachment = request.attachment {
            defaults.set(
                attachment.noteID.uuidString,
                forKey: PermissionResumeKey.attachedNoteID
            )
            defaults.set(attachment.filePath, forKey: PermissionResumeKey.attachedNotePath)
        } else {
            defaults.removeObject(forKey: PermissionResumeKey.attachedNoteID)
            defaults.removeObject(forKey: PermissionResumeKey.attachedNotePath)
        }
    }

    private static func permissionRequired(
        for error: Error
    ) -> NookPermission? {
        if let captureError = error as? CaptureError {
            switch captureError {
            case .screenRecordingPermissionDenied:
                return .screenRecording
            case .microphonePermissionDenied:
                return .microphone
            default:
                return nil
            }
        }
        if let transcriptionError = error as? TranscriptionError,
           case .permissionDenied = transcriptionError {
            return .speechRecognition
        }
        return nil
    }

    /// Set while the application is quitting, so finalization is given a
    /// shorter deadline than it gets during ordinary use.
    private var isTerminating = false

    /// How long the final summary is allowed to take.
    ///
    /// It had no bound at all, so a wedged on-device model held the save, and
    /// therefore a quit, open indefinitely. The budget scales with the
    /// transcript because a long meeting legitimately needs several condensing
    /// rounds, and collapses on quit because nobody waits minutes for an
    /// application to close.
    static func summaryDeadline(
        forTranscriptCharacters characters: Int,
        isTerminating: Bool
    ) -> TimeInterval {
        if isTerminating { return summaryQuitDeadline }
        return min(900, max(90, 60 + Double(characters) / 200))
    }

    static let summaryQuitDeadline: TimeInterval = 25

    func summaryDeadline(forTranscriptCharacters characters: Int) -> TimeInterval {
        Self.summaryDeadline(
            forTranscriptCharacters: characters,
            isTerminating: isTerminating
        )
    }

    /// Summarizes within a bound, falling back to the deterministic insights
    /// and saying so when the deadline wins.
    private func summarizedWithinDeadline(
        transcript: [TranscriptSegment],
        fallbackTitle: String,
        attention: SummaryAttention? = nil
    ) async -> SummaryResult {
        let characters = transcript.reduce(0) { $0 + $1.text.count }
        let seconds = summaryDeadline(forTranscriptCharacters: characters)
        let progressGeneration = beginSummaryProgress()
        let result = await withDeadline(seconds: seconds) {
            [weak self, summarizer] () -> SummaryResult in
            await summarizer.summarizeReportingFailure(
                transcript: transcript,
                fallbackTitle: fallbackTitle,
                attention: attention,
                onProgress: { part, total in
                    await MainActor.run {
                        guard let self,
                              Self.shouldApplySummaryProgress(
                                  generation: progressGeneration,
                                  currentGeneration: self.summaryProgressGeneration
                              )
                        else {
                            return
                        }
                        self.summaryProgress = SummaryProgress(
                            part: part,
                            total: total
                        )
                    }
                }
            )
        }
        endSummaryProgress(for: progressGeneration)
        if let result { return result }
        NookEventLog.write(.summaryTimedOut)
        return SummaryResult(
            insights: SummaryService.fallbackInsights(
                transcript: transcript,
                fallbackTitle: fallbackTitle,
                reason: .timedOut
            ),
            failure: .timedOut
        )
    }

    private func beginSummaryProgress() -> Int {
        summaryProgressGeneration &+= 1
        summaryProgress = nil
        return summaryProgressGeneration
    }

    private func endSummaryProgress(for generation: Int) {
        guard summaryProgressGeneration == generation else { return }
        summaryProgressGeneration &+= 1
        summaryProgress = nil
    }

    private func invalidateSummaryProgress() {
        summaryProgressGeneration &+= 1
        summaryProgress = nil
    }

    /// A late callback from an older model pass must not repopulate the
    /// progress indicator after that pass timed out or the meeting moved on.
    nonisolated static func shouldApplySummaryProgress(
        generation: Int,
        currentGeneration: Int
    ) -> Bool {
        generation == currentGeneration
    }

    /// Builds the note that must be useful before the on-device model gets a
    /// turn. The deterministic fallback is deliberately written first, so a
    /// model refusal or a timeout never leaves the transcript stranded in a
    /// temporary processing state.
    static func transcriptFirstScaffold(
        for draft: MeetingDraft,
        transcript: [TranscriptSegment],
        personalNotes: String,
        moments: [MeetingMoment],
        endedAt: Date
    ) -> MeetingNote {
        let fallback: MeetingInsights
        if transcript.isEmpty {
            // Keep the empty-input result identical to SummaryService's
            // existing fast path. A no-speech recording should not acquire a
            // different explanation merely because it is saved earlier.
            fallback = MeetingInsights(
                title: draft.title,
                summary: "No speech was detected in this recording.",
                keyPoints: [],
                decisions: [],
                actionItems: []
            )
        } else {
            fallback = SummaryService.fallbackInsights(
                transcript: transcript,
                fallbackTitle: draft.title
            )
        }
        return MeetingNote(
            id: draft.id,
            kind: .meeting,
            title: fallback.title,
            startedAt: draft.startedAt,
            endedAt: endedAt,
            sourceApp: draft.sourceApp,
            summary: fallback.summary,
            keyPoints: fallback.keyPoints,
            decisions: fallback.decisions,
            actionItems: fallback.actionItems,
            personalNotes: personalNotes,
            transcript: transcript,
            moments: moments
        )
    }

    /// Applies a successful model result only to fields that still equal the
    /// scaffold. Every other field starts from the freshest store copy, so a
    /// title edit, note, flag, checkbox, extra section, or metadata update
    /// made while the model worked remains authoritative.
    ///
    /// A missing note means somebody deleted it while enrichment was running.
    /// Returning nil lets the caller finish without recreating that deletion.
    static func mergingTranscriptFirstSummary(
        _ result: SummaryResult,
        scaffold: MeetingNote,
        current: MeetingNote?
    ) -> MeetingNote? {
        guard let current, current.libraryIdentity == scaffold.libraryIdentity else { return nil }
        guard result.failure == nil else { return current }
        // The model was grounded in the scaffold transcript. If that source
        // changed while it worked, keeping the current note is safer than
        // applying claims that no longer have the same evidence.
        guard exactTranscriptMatches(current.transcript, scaffold.transcript) else { return current }

        var merged = current
        if current.title.utf8.elementsEqual(scaffold.title.utf8) {
            merged.title = result.insights.title
        }
        if current.summary.utf8.elementsEqual(scaffold.summary.utf8) {
            merged.summary = result.insights.summary
        }
        if exactStringsMatch(current.keyPoints, scaffold.keyPoints) {
            merged.keyPoints = result.insights.keyPoints
        }
        if exactStringsMatch(current.decisions, scaffold.decisions) {
            merged.decisions = result.insights.decisions
        }
        if exactStringsMatch(current.actionItems, scaffold.actionItems),
           exactStringsMatch(current.completedActionItems.sorted(), scaffold.completedActionItems.sorted()) {
            merged.actionItems = result.insights.actionItems
        }
        return merged
    }

    /// A refreshed file revision does not give a delayed model ownership of
    /// a Unicode-only edit. Swift's canonical equality hides those changes,
    /// including strings inside arrays and completed-action sets.
    private static func exactStringsMatch(_ left: [String], _ right: [String]) -> Bool {
        left.count == right.count
            && zip(left, right).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }

    private static func exactTranscriptMatches(
        _ left: [TranscriptSegment], _ right: [TranscriptSegment]
    ) -> Bool {
        // Preserve the existing identity/timing/source check as well as exact
        // wording: a normalization edit is still a changed generation input.
        left == right && zip(left, right).allSatisfy {
            $0.text.utf8.elementsEqual($1.text.utf8)
        }
    }

    /// Reads the durable Markdown itself rather than trusting an in-memory
    /// model left over from before a failed save or an external deletion.
    /// Candidates are restricted to the captured scaffold owner. A same-UUID
    /// copy or renamed path cannot stand in for its original destination.
    private static func persistedNote(
        id: UUID,
        candidateURLs: [URL?]
    ) -> MeetingNote? {
        var checked: Set<URL> = []
        for candidate in candidateURLs.compactMap({ $0 }) {
            let url = candidate.standardizedFileURL
            guard checked.insert(url).inserted,
                  FileManager.default.fileExists(atPath: url.path),
                  let markdown = try? String(contentsOf: url, encoding: .utf8),
                  let decoded = MarkdownCodec.decode(markdown, fileURL: url),
                  decoded.id == id
            else {
                continue
            }
            return decoded
        }
        return nil
    }

    private func finishRecording() async {
        guard let draft = activeDraft else {
            phase = .failed("Nook lost track of the active meeting.")
            processingTask = nil
            return
        }

        let audioURL = draft.recordingURL
            .deletingPathExtension()
            .appendingPathExtension("m4a")
        let personalNotes = liveNotes.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        var recordingURLs: [URL] = []
        // Kept outside the do block because a failure anywhere after this
        // point still has to be able to save them: they are the only
        // transcript of the meeting that survives a finalize that went wrong.
        var liveSegments: [TranscriptSegment] = []
        // Once this exists, cancellation removes the scaffold along with the
        // recording. Before it exists, the old recovery path remains intact.
        var transcriptFirstScaffold: MeetingNote?
        // Total unpaused seconds of captured audio, as of the moment stop was
        // requested. The live transcript timeline only advances with delivered
        // audio (ingest is gated off while paused), so this is the reference
        // frame its coverage is judged against.
        let recordedSeconds = accumulatedElapsed
            + (activeElapsedStartedAt.map { Date().timeIntervalSince($0) } ?? 0)
        do {
            liveStartupTask?.cancel()
            liveStartupTask = nil
            liveSummaryTask?.cancel()
            liveSummaryTask = nil
            liveSummaryIsRefreshing = false
            recordingURLs = try await capture.stop(
                finalizationTimeout: isTerminating
                    ? CaptureService.quitFinalizationTimeout
                    : nil
            )
            liveSegments = await liveTranscriber.stop()
            try Task.checkCancellation()
            phase = .processing(.preparing)
            try await AudioExtractor.extractAudio(
                from: recordingURLs,
                to: audioURL
            )
            try Task.checkCancellation()

            phase = .processing(.refining)
            let rawTranscript: [TranscriptSegment]
            if liveTranscriptIsComplete,
               liveSegments.reduce(0, { $0 + $1.text.count }) >= 40,
               Self.liveSegmentsCoverRecording(
                   liveSegments,
                   recordedSeconds: recordedSeconds
               ) {
                rawTranscript = liveSegments
            } else {
                phase = .processing(.transcribing)
                rawTranscript = try await transcriber.transcribe(
                    audioURL: audioURL,
                    localeIdentifier: localeIdentifier
                )
            }
            try Task.checkCancellation()
            let transcript = TranscriptAssembler.coalesce(rawTranscript)

            // A recording started from an existing note joins that note
            // instead of creating one; everything downstream differs.
            if draft.attachedNoteID != nil {
                let target = try requireAttachedTarget(for: draft)
                let (saved, cleanupFailures) = try await appendFinalizedSession(
                    to: target,
                    draft: draft,
                    sessionTranscript: transcript,
                    sessionAudioURL: audioURL,
                    recordingURLs: recordingURLs
                )
                completeSuccessfulProcessing(
                    cleanupFailures: cleanupFailures,
                    title: saved.title
                )
                return
            }

            phase = .processing(.saving)
            let scaffold = Self.transcriptFirstScaffold(
                for: draft,
                transcript: transcript,
                personalNotes: personalNotes,
                moments: liveMoments,
                endedAt: Date()
            )
            let savedScaffold = try store.save(scaffold)
            transcriptFirstScaffold = savedScaffold
            try Task.checkCancellation()

            phase = .processing(.summarizing)
            let attention = SummaryAttention(
                myNotes: personalNotes,
                moments: liveMoments,
                transcript: transcript
            )
            let result = await summarizedWithinDeadline(
                transcript: transcript,
                fallbackTitle: draft.title,
                attention: attention.isEmpty ? nil : attention
            )
            try Task.checkCancellation()

            phase = .processing(.saving)
            let current = Self.attachedRecordingTarget(
                expected: savedScaffold.libraryIdentity,
                notes: store.notes,
                libraryURL: store.storageURL
            )
            let currentFileExists = current?.fileURL.map {
                FileManager.default.fileExists(atPath: $0.path)
            } ?? false
            let merged = Self.mergingTranscriptFirstSummary(
                result,
                scaffold: savedScaffold,
                current: currentFileExists ? current : nil
            )
            var persistedCandidate = current
            if !result.usedFallback, let current, let merged, merged != current {
                // A conflict means the transcript-first note remains the
                // durable result. It must not enter the older rescue branch,
                // which would create a second note from the same captions.
                persistedCandidate = (try? store.save(merged)) ?? current
            }
            let freshest = store.note(matching: savedScaffold.libraryIdentity)
            guard let saved = Self.persistedNote(
                id: savedScaffold.id,
                candidateURLs: [
                    freshest?.fileURL,
                    persistedCandidate?.fileURL,
                    savedScaffold.fileURL,
                ]
            ) else {
                throw DurableMeetingNoteUnavailable(
                    reason: "Nook saved the transcript, but the note file disappeared before processing finished."
                )
            }

            let cleanupFailures = RecordingArtifactCleanup.removeArtifacts(
                for: draft,
                additionalURLs: recordingURLs + [audioURL],
                preserving: keepAudio ? Set([audioURL]) : []
            )

            completeSuccessfulProcessing(
                cleanupFailures: cleanupFailures,
                title: saved.title
            )
        } catch {
            if Task.isCancelled || processingCancellationRequested {
                if let transcriptFirstScaffold {
                    _ = store.delete(transcriptFirstScaffold)
                }
                await discardCancelledMeeting(
                    draft: draft,
                    additionalURLs: recordingURLs + [audioURL]
                )
                return
            }
            liveStartupTask?.cancel()
            liveStartupTask = nil
            liveSummaryTask?.cancel()
            liveSummaryTask = nil
            liveSummaryIsRefreshing = false
            invalidateSummaryProgress()
            // The live captions are the only transcript that survives a
            // failed finalize, so the track is stopped for its words rather
            // than cancelled. Cancelling threw an hour of already-recognised
            // conversation away and left the user a failure notice for a
            // meeting Nook had, in fact, heard.
            if liveSegments.isEmpty, liveTranscriber.isRunning {
                liveSegments = await liveTranscriber.stop()
            } else if liveTranscriber.isRunning {
                await liveTranscriber.cancel()
            }
            if transcriptFirstScaffold == nil,
               !(error is DurableMeetingNoteUnavailable),
               await saveLiveCaptionNote(
                draft: draft,
                segments: liveSegments,
                personalNotes: personalNotes
            ) {
                return
            }
            // Cancellation can arrive while the bounded live-caption summary
            // is awaiting its model. That helper deliberately returns without
            // saving; route the now-cancelled meeting through the same discard
            // cleanup as a cancellation caught earlier, rather than turning it
            // into a processing failure with a preserved recording.
            if Task.isCancelled || processingCancellationRequested {
                await discardCancelledMeeting(
                    draft: draft,
                    additionalURLs: recordingURLs + [audioURL]
                )
                return
            }
            // The recording is deliberately kept.
            //
            // Deleting it here treated every failure as though the audio were
            // worthless, when the opposite is true: processing failed, so the
            // recording is the only copy of the meeting that exists. Somebody
            // whose Mac took a moment too long to finish writing a file lost an
            // hour of conversation for it. Cancelling a meeting still discards
            // everything, because that is the user asking.
            activeDraft = nil
            processingTask = nil
            live.elapsed = 0
            accumulatedElapsed = 0
            activeElapsedStartedAt = nil
            isPaused = false
            pauseTransitionInFlight = false
            live.audioLevel = 0
            processingCancellationRequested = false
            processingOwnsAttachedScaffold = false
            stopRequestedDuringPauseTransition = false
            phase = .failed(
                error.localizedDescription
                    + Self.preservedRecordingNotice(
                        for: recordingURLs.isEmpty
                            ? Array(RecordingArtifactCleanup.artifactURLs(for: draft))
                            : recordingURLs
                    )
            )
            NookEventLog.write(.meetingProcessingFailed)
            onPresentationRequested?()
        }
    }

    /// What a note says when its words came from the live captions rather
    /// than from the recording Nook could not finish.
    static let liveCaptionNoteMarker = """
        This note was built from the live captions. Nook could not finish the \
        recording, so the saved audio was not used and words near the end may \
        be missing. The recording was kept, so a full transcript can still be \
        recovered from it.
        """

    /// Saves what the live captions heard when finalizing the recording
    /// failed. Returns false when there was nothing worth saving, or saving
    /// it also failed.
    ///
    /// Everything up to the failure is real conversation Nook already
    /// recognised. Discarding it because the capture file would not close, or
    /// because the saved-audio pass threw, is the worst outcome available: the
    /// meeting is over, and those words are the only copy of it left. The
    /// recording still stays on disk, so a better transcript remains
    /// recoverable.
    private func saveLiveCaptionNote(
        draft: MeetingDraft,
        segments: [TranscriptSegment],
        personalNotes: String
    ) async -> Bool {
        let transcript = TranscriptAssembler.coalesce(segments)
        guard transcript.reduce(0, { $0 + $1.text.count }) >= 40 else {
            return false
        }
        if draft.attachedNoteID != nil,
           (try? requireAttachedTarget(for: draft)) == nil {
            return false
        }

        phase = .processing(.summarizing)
        let attention = SummaryAttention(
            myNotes: personalNotes,
            moments: liveMoments,
            transcript: transcript
        )
        let insights = await summarizedWithinDeadline(
            transcript: transcript,
            fallbackTitle: draft.title,
            attention: attention.isEmpty ? nil : attention
        ).insights
        guard !Task.isCancelled, !processingCancellationRequested else {
            return false
        }
        phase = .processing(.saving)

        do {
            let saved: MeetingNote
            if draft.attachedNoteID != nil {
                let target = try requireAttachedTarget(for: draft)
                saved = try store.save(
                    Self.appendingLiveCaptions(
                        transcript: transcript,
                        moments: liveMoments,
                        personalNotes: personalNotes,
                        startedAt: draft.startedAt,
                        to: target
                    )
                )
            } else {
                // A fresh identifier on purpose: the recording keeps the
                // draft's, and the recovery list only offers recordings whose
                // identifier belongs to no saved note. Reusing it here would
                // save the words and quietly hide the audio that could still
                // produce better ones.
                saved = try store.save(
                    MeetingNote(
                        id: UUID(),
                        title: insights.title,
                        startedAt: draft.startedAt,
                        endedAt: Date(),
                        sourceApp: draft.sourceApp,
                        summary: Self.liveCaptionNoteMarker
                            + "\n\n"
                            + insights.summary,
                        keyPoints: insights.keyPoints,
                        decisions: insights.decisions,
                        actionItems: insights.actionItems,
                        personalNotes: personalNotes,
                        transcript: transcript,
                        moments: liveMoments
                    )
                )
            }
            NookEventLog.write(.meetingSavedFromLiveCaptions)
            completeSuccessfulProcessing(
                cleanupFailures: [],
                title: saved.title
            )
            return true
        } catch {
            return false
        }
    }

    /// Joins live-caption material onto an existing note without touching its
    /// audio, which is exactly what could not be finalized.
    static func appendingLiveCaptions(
        transcript: [TranscriptSegment],
        moments: [MeetingMoment],
        personalNotes: String,
        startedAt: Date,
        to target: MeetingNote
    ) -> MeetingNote {
        var promoted = target
        NoteSessionAppend.promoteSpokenToMeeting(&promoted)
        var updated = NoteSessionAppend.appending(
            material: NoteSessionAppend.Material(
                startedAt: startedAt,
                endedAt: Date(),
                transcript: transcript,
                moments: moments,
                personalNotes: personalNotes
            ),
            to: promoted,
            offset: NoteSessionAppend.continuationOffset(
                for: promoted,
                priorAudioDuration: nil
            ),
            audioStart: promoted.audioStart
        )
        let existing = updated.summary.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        updated.summary = existing.isEmpty
            ? liveCaptionNoteMarker
            : existing + "\n\n" + liveCaptionNoteMarker
        return updated
    }

    /// Shared tail of every successful finalize, whether the recording
    /// created a note or joined one.
    private func completeSuccessfulProcessing(
        cleanupFailures: [URL],
        title: String
    ) {
        activeDraft = nil
        processingTask = nil
        live.elapsed = 0
        accumulatedElapsed = 0
        activeElapsedStartedAt = nil
        isPaused = false
        pauseTransitionInFlight = false
        live.audioLevel = 0
        liveCaptionNotice = nil
        liveNotes = ""
        liveInsights = nil
        liveSummaryUpdatedAt = nil
        invalidateSummaryProgress()
        topPanelHidden = false
        processingCancellationRequested = false
        processingOwnsAttachedScaffold = false
        stopRequestedDuringPauseTransition = false
        if cleanupFailures.isEmpty {
            phase = .completed(title)
            NookEventLog.write(.meetingSaved)
        } else {
            phase = .failed(
                "Your meeting note was saved, but Nook could not remove every temporary recording file."
                    + Self.cleanupNotice(for: cleanupFailures)
            )
        }
        onPresentationRequested?()
    }

    /// What happens to the note's kept audio when a sitting is appended.
    enum KeptAudioPlan: Equatable, Sendable {
        /// No audio is kept for this note, and none is being added.
        case none
        /// This sitting's audio becomes the note's kept file.
        case adoptSession
        /// This sitting's audio is joined onto the file already there.
        case concatenate
        /// Earlier audio stays exactly as it is, and this sitting adds none.
        case keepPriorOnly
    }

    /// Decides what to do with audio when a sitting joins a note.
    ///
    /// Two rules make this less obvious than it looks. Audio kept under an
    /// earlier promise is never destroyed, including a file that exists but
    /// cannot be measured, which the previous shape deleted outright. And
    /// turning audio retention off means this sitting's audio is not kept,
    /// so it is not concatenated onto the note's file either.
    static func keptAudioPlan(
        keepAudio: Bool,
        priorAudioExists: Bool,
        priorAudioIsReadable: Bool
    ) -> KeptAudioPlan {
        let usablePrior = priorAudioExists && priorAudioIsReadable
        if usablePrior {
            return keepAudio ? .concatenate : .keepPriorOnly
        }
        if keepAudio { return .adoptSession }
        return priorAudioExists ? .keepPriorOnly : .none
    }

    /// Finishes a recording that was started from an existing note.
    ///
    /// The sitting joins the note on one continuous timeline: kept audio is
    /// concatenated onto what was there (or becomes the note's first audio),
    /// transcript offsets continue where the note left off, and the summary is
    /// regenerated over the combined material. Personal notes, including
    /// everything typed during this sitting, are never rewritten. Neither is a
    /// title the user chose, nor an action item they are still tracking.
    private func appendFinalizedSession(
        to target: MeetingNote,
        draft: MeetingDraft,
        sessionTranscript: [TranscriptSegment],
        sessionAudioURL: URL,
        recordingURLs: [URL]
    ) async throws -> (note: MeetingNote, cleanupFailures: [URL]) {
        _ = try requireAttachedTarget(for: draft)
        let recordingsDirectory = store.recordingsDirectory()
        let priorAudioURL = recordingsDirectory
            .appendingPathComponent("\(target.id.uuidString).m4a")
        let audio = try await Self.inspectAppendedAudio(
            priorAudioURL: priorAudioURL,
            sessionAudioURL: sessionAudioURL
        )
        let priorAudioExists = audio.prior.exists
        let priorAudioDuration = audio.priorDuration
        let currentTarget = try requireAttachedTarget(for: draft)
        guard currentTarget.libraryIdentity == target.libraryIdentity else {
            throw DurableMeetingNoteUnavailable(reason: Self.unavailableAttachmentMessage)
        }
        // A file that exists but cannot be measured cannot be concatenated
        // safely either, so it is treated like absent audio rather than
        // trusted with the timeline.
        let hadUsablePriorAudio = priorAudioExists && priorAudioDuration != nil
        let plan = Self.keptAudioPlan(
            keepAudio: keepAudio,
            priorAudioExists: priorAudioExists,
            priorAudioIsReadable: priorAudioDuration != nil
        )

        // Audio time is the clock moments play back against, so when kept
        // audio exists its length decides where this sitting begins. Any gap
        // between audio and transcript extent is real recorded time.
        let offset = hadUsablePriorAudio
            ? currentTarget.audioStart + (priorAudioDuration ?? 0)
            : NoteSessionAppend.continuationOffset(
                for: currentTarget,
                priorAudioDuration: nil
            )

        var promotedTarget = currentTarget
        NoteSessionAppend.promoteSpokenToMeeting(&promotedTarget)

        let material = NoteSessionAppend.Material(
            startedAt: draft.startedAt,
            endedAt: Date(),
            transcript: sessionTranscript,
            moments: liveMoments,
            personalNotes: liveNotes.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        )
        // Only an adopted session file starts the note's audio partway along
        // the timeline. Every other plan leaves the note's audio, and so its
        // start, exactly where it already was.
        let combinedAudioStart = plan == .adoptSession
            ? offset
            : currentTarget.audioStart

        let appended = NoteSessionAppend.appending(
            material: material,
            to: promotedTarget,
            offset: offset,
            audioStart: combinedAudioStart
        )
        phase = .processing(.saving)
        try Task.checkCancellation()
        let saved: MeetingNote
        do {
            saved = try store.save(appended) {
                _ = try self.requireAttachedTarget(for: draft)
                try audio.validate()
            }
        } catch {
            throw DurableMeetingNoteUnavailable(
                reason: "Nook could not append the transcript to its existing note."
            )
        }
        processingOwnsAttachedScaffold = true

        // Every irreversible move happens after the note is safely on disk.
        // Rewriting the note's audio first meant a failed save left the file
        // describing a sitting no note mentioned.
        var preserve: Set<URL> = []
        var audioFailures: [URL] = []
        do {
            try await placeKeptAudio(
                plan,
                for: draft,
                audio: audio,
                asideURL: recordingsDirectory.appendingPathComponent(
                    "\(target.id.uuidString)-unreadable-\(draft.id.uuidString).m4a"
                )
            )
            if plan != .none { preserve.insert(priorAudioURL) }
        } catch let stranded as KeptAudioStranded {
            // Neither move worked and the old file could not go back, so the
            // note's earlier audio is no longer where the note points at it.
            // Preserving it keeps the cleanup pass off it; naming it in the
            // notice is reserved for the case where nothing else will list it,
            // because telling somebody to go and find a file they can already
            // recover from Settings is worse than saying nothing.
            NookEventLog.write(.keptAudioStranded)
            audioFailures.append(sessionAudioURL)
            preserve.insert(stranded.strandedURL)
            if !stranded.isListedByRecoveryScan {
                audioFailures.append(stranded.strandedURL)
            }
            preserve.formUnion(Self.sessionArtifactsAfterAudioFailure(
                draft: draft, recordingURLs: recordingURLs, sessionAudioURL: sessionAudioURL
            ))
        } catch {
            // The note is already saved, so audio that would not move is
            // reported like any other file the user may have to handle, not
            // turned into a failed meeting. A changed audio source is not
            // covered by the saved timeline, so retain the session's captures
            // too, even when normal retention was off. Recovery must still
            // have the originals rather than only a replacement at one path.
            audioFailures.append(sessionAudioURL)
            preserve.formUnion(Self.sessionArtifactsAfterAudioFailure(
                draft: draft, recordingURLs: recordingURLs, sessionAudioURL: sessionAudioURL
            ))
        }

        // Audio placement can suspend. Keep the raw recording if the saved
        // destination was deleted, copied, or its library changed meanwhile.
        _ = try requireAttachedTarget(for: draft)
        let cleanupFailures = RecordingArtifactCleanup.removeArtifacts(
            for: draft,
            additionalURLs: recordingURLs + [sessionAudioURL],
            preserving: preserve
        )
        scheduleAppendedSummaryEnrichment(
            scaffold: saved,
            fallbackTitle: currentTarget.title.isEmpty
                ? draft.title
                : currentTarget.title
        )
        return (saved, audioFailures + cleanupFailures)
    }

    /// Enriches an appended sitting only after its transcript is durable.
    /// The note remains useful if the model is slow or unavailable, while the
    /// token and optimistic merge keep an older pass from overwriting a later
    /// append or anything the user changed in the meantime.
    private func scheduleAppendedSummaryEnrichment(
        scaffold: MeetingNote,
        fallbackTitle: String
    ) {
        let noteID = scaffold.id
        appendedSummaryTasks[noteID]?.cancel()

        let token = UUID()
        appendedSummaryTokens[noteID] = token
        let characters = scaffold.transcript.reduce(0) { $0 + $1.text.count }
        let seconds = Self.summaryDeadline(
            forTranscriptCharacters: characters,
            isTerminating: isTerminating
        )
        let attention = SummaryAttention(
            myNotes: scaffold.personalNotes,
            moments: scaffold.moments,
            transcript: scaffold.transcript
        )

        appendedSummaryTasks[noteID] = Task { @MainActor [weak self, summarizer] in
            guard let self else { return }
            defer {
                if self.appendedSummaryTokens[noteID] == token {
                    self.appendedSummaryTokens[noteID] = nil
                    self.appendedSummaryTasks[noteID] = nil
                }
            }

            let result = await withDeadline(seconds: seconds) {
                await summarizer.summarizeReportingFailure(
                    transcript: scaffold.transcript,
                    fallbackTitle: fallbackTitle,
                    attention: attention.isEmpty ? nil : attention
                )
            }
            guard !Task.isCancelled,
                  self.appendedSummaryTokens[noteID] == token,
                  let result,
                  !result.usedFallback,
                  let current = Self.attachedRecordingTarget(
                      expected: scaffold.libraryIdentity,
                      notes: self.store.notes,
                      libraryURL: self.store.storageURL
                  ),
                  let merged = Self.mergingAppendedSessionSummary(
                      result,
                      scaffold: scaffold,
                      current: current
                  ),
                  merged != current
            else {
                return
            }
            _ = try? self.store.save(merged)
        }
    }

    /// Applies generated fields only when their scaffold values remain
    /// untouched. A transcript change invalidates the model's evidence, and a
    /// missing note represents an intentional deletion that must not be
    /// recreated by a late result.
    static func mergingAppendedSessionSummary(
        _ result: SummaryResult,
        scaffold: MeetingNote,
        current: MeetingNote?
    ) -> MeetingNote? {
        guard let current, current.libraryIdentity == scaffold.libraryIdentity else { return nil }
        guard result.failure == nil else { return current }
        guard exactTranscriptMatches(current.transcript, scaffold.transcript) else { return current }

        var merged = current
        if current.title.utf8.elementsEqual(scaffold.title.utf8) {
            merged.title = mergedTitle(
                existing: scaffold.title,
                proposed: result.insights.title
            )
        }
        if current.summary.utf8.elementsEqual(scaffold.summary.utf8) {
            merged.summary = result.insights.summary
        }
        if exactStringsMatch(current.keyPoints, scaffold.keyPoints) {
            merged.keyPoints = result.insights.keyPoints
        }
        if exactStringsMatch(current.decisions, scaffold.decisions) {
            merged.decisions = result.insights.decisions
        }
        if exactStringsMatch(current.actionItems, scaffold.actionItems),
           exactStringsMatch(current.completedActionItems.sorted(), scaffold.completedActionItems.sorted()) {
            merged.actionItems = unionedActionItems(
                existing: scaffold.actionItems,
                proposed: result.insights.actionItems
            )
        }
        return merged
    }

    struct AppendedAudioSources: Sendable {
        let prior: NoteCombiner.AudioFileSnapshot
        let session: NoteCombiner.AudioFileSnapshot
        let priorDuration: TimeInterval?

        func validate() throws {
            try prior.validate()
            try session.validate()
        }
    }

    /// The measured duration belongs to the file observed before that await.
    /// Replacing the recording during measurement must not authorize a stale
    /// transcript offset, even if the note's Markdown itself is unchanged.
    static func inspectAppendedAudio(
        priorAudioURL: URL,
        sessionAudioURL: URL,
        measure: @MainActor (URL) async -> TimeInterval? = { url in
            await NoteSessionAppend.audioDuration(of: url)
        }
    ) async throws -> AppendedAudioSources {
        let prior = try NoteCombiner.AudioFileSnapshot(url: priorAudioURL)
        let session = try NoteCombiner.AudioFileSnapshot(url: sessionAudioURL)
        guard session.exists else { throw NoteCombiner.CombineError.audioChanged }
        let duration = prior.exists ? await measure(priorAudioURL) : nil
        try Task.checkCancellation()
        try prior.validate()
        try session.validate()
        return AppendedAudioSources(prior: prior, session: session, priorDuration: duration)
    }

    static func sessionArtifactsAfterAudioFailure(
        draft: MeetingDraft, recordingURLs: [URL], sessionAudioURL: URL
    ) -> Set<URL> {
        Set(recordingURLs + [draft.recordingURL, sessionAudioURL])
    }

    private func placeKeptAudio(
        _ plan: KeptAudioPlan,
        for draft: MeetingDraft,
        audio: AppendedAudioSources,
        asideURL: URL
    ) async throws {
        _ = try requireAttachedTarget(for: draft)
        try audio.validate()
        let manager = FileManager.default
        let priorAudioURL = audio.prior.url
        let sessionAudioURL = audio.session.url
        switch plan {
        case .none, .keepPriorOnly:
            return
        case .concatenate:
            try await Self.concatenateAppendedAudio(audio) {
                _ = try requireAttachedTarget(for: draft)
            }
        case .adoptSession:
            try Self.adoptSessionAudio(
                priorExists: manager.fileExists(atPath: priorAudioURL.path),
                priorAudioURL: priorAudioURL,
                sessionAudioURL: sessionAudioURL,
                asideURL: asideURL,
                recoverableURL: asideURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("\(UUID().uuidString).m4a"),
                move: { try manager.moveItem(at: $0, to: $1) }
            )
        }
    }

    /// The same captured files must still own both the measured timeline and
    /// the combined output. Metadata checks narrow the replacement race;
    /// this is not a filesystem transaction against uncooperative writers.
    static func concatenateAppendedAudio(
        _ audio: AppendedAudioSources,
        extract: @MainActor ([URL], URL) async throws -> Void = { sources, destination in
            try await AudioExtractor.extractAudio(from: sources, to: destination)
        },
        validatingBeforeReplacement: @MainActor () throws -> Void
    ) async throws {
        try audio.validate()
        let temporary = audio.prior.url.deletingLastPathComponent()
            .appendingPathComponent("combined-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await extract([audio.prior.url, audio.session.url], temporary)
        try Task.checkCancellation()
        try validatingBeforeReplacement()
        try audio.validate()
        _ = try FileManager.default.replaceItemAt(audio.prior.url, withItemAt: temporary)
    }

    /// The two moves that make a session recording become the note's audio.
    ///
    /// They are two operations and not one, so the window between them is real:
    /// the old file has been renamed to something nothing scans, and the new
    /// one has not arrived yet. A failure there used to leave the note pointing
    /// at a path with nothing in it while its audio sat under a name only a
    /// Finder search would find. The old file goes back first; only if that
    /// fails too is the audio reported by name, and it is reported rather than
    /// left silent.
    ///
    /// The file operations are a parameter so the failure ordering, which is
    /// the part that can lose a recording, can be tested without a FileManager
    /// that fails on demand.
    nonisolated static func adoptSessionAudio(
        priorExists: Bool,
        priorAudioURL: URL,
        sessionAudioURL: URL,
        asideURL: URL,
        recoverableURL: URL,
        move: (URL, URL) throws -> Void
    ) throws {
        // An unreadable file is moved aside rather than deleted. Its stem is
        // deliberately not a bare identifier, so neither the recovery scan nor
        // artifact cleanup mistakes it for a loose recording.
        if priorExists {
            try move(priorAudioURL, asideURL)
        }
        do {
            try move(sessionAudioURL, priorAudioURL)
        } catch {
            guard priorExists else { throw error }
            // Undo the rename first. The note then keeps exactly the audio it
            // had before this sitting, which is a whole outcome rather than a
            // gap, and the caller reports only the session file that would not
            // move.
            if (try? move(asideURL, priorAudioURL)) != nil { throw error }
            // It would not go back either. A name the recovery scan lists is
            // the difference between audio Settings offers back and audio only
            // a Finder search would ever find.
            if (try? move(asideURL, recoverableURL)) != nil {
                throw KeptAudioStranded(
                    strandedURL: recoverableURL,
                    isListedByRecoveryScan: true,
                    underlying: error
                )
            }
            throw KeptAudioStranded(
                strandedURL: asideURL,
                isListedByRecoveryScan: false,
                underlying: error
            )
        }
    }

    /// Whether a title is Nook's own placeholder rather than something the
    /// user named or accepted.
    ///
    /// Compared against no fallback on purpose. Recording into a note starts
    /// the draft with that note's title, so passing the draft's title here
    /// would call every title a placeholder and quietly overwrite names people
    /// chose.
    static func isPlaceholderTitle(_ title: String) -> Bool {
        MeetingTitleGenerator.isFallbackTitle(title, fallbackTitle: "")
    }

    /// Keeps the title the note already has unless it was never really named.
    static func mergedTitle(existing: String, proposed: String) -> String {
        guard isPlaceholderTitle(existing) else { return existing }
        return isPlaceholderTitle(proposed) ? existing : proposed
    }

    /// Joins newly generated actions onto the ones already in the note.
    ///
    /// Replacing them lost work: an item the user had edited, dated, or ticked
    /// off simply vanished because a second sitting did not mention it again.
    /// Existing strings are kept byte for byte, including any `[due: ...]`
    /// suffix and checkbox state, and only genuinely new items are added.
    static func unionedActionItems(
        existing: [String],
        proposed: [String]
    ) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for item in existing + proposed {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = actionItemKey(trimmed)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    /// Matches two wordings of the same commitment: the due suffix and the
    /// checkbox marker are Nook's bookkeeping, not part of what was said.
    private static func actionItemKey(_ item: String) -> String {
        item
            .replacingOccurrences(
                of: #"^\s*(?:[-*]\s*)?(?:\[[ xX]\])?\s*"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\s*\[due:\s*\d{4}-\d{2}-\d{2}\]\s*"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// Tells the user where the audio went when processing could not finish.
    ///
    /// Whether the live transcript plausibly spans the whole recording.
    ///
    /// A live track can lose its recognizer without any error reaching Nook,
    /// leaving words that stop growing long before the audio does. Trusting
    /// such a transcript would save a two-hour meeting as its first twenty
    /// minutes, flagged complete. When any source's last words end well short
    /// of the recording, the slower saved-audio pass runs instead. Trailing
    /// silence can trip this needlessly; that costs processing time, while
    /// missing it costs the meeting.
    static func liveSegmentsCoverRecording(
        _ segments: [TranscriptSegment],
        recordedSeconds: TimeInterval
    ) -> Bool {
        // Very short meetings are cheaper to re-transcribe than to judge.
        guard recordedSeconds > 30 else { return true }
        let coverageEndBySource = Dictionary(grouping: segments, by: \.source)
            .mapValues { values in
                values.reduce(TimeInterval(0)) {
                    max($0, $1.startTime + $1.duration)
                }
            }
        guard coverageEndBySource.values.allSatisfy({
            $0 >= recordedSeconds * 0.75
        }) else {
            return false
        }
        // The ratio alone still accepts a track that stalls inside the last
        // quarter, and a quarter of a two hour meeting is half an hour of
        // conversation missing.
        //
        // The tail window is measured against the track that lasted longest,
        // not against the recording. Everyone falling quiet at the end is
        // ordinary and ends both tracks together, so measuring from the
        // recording would condemn every meeting with a long closing silence.
        // One recognizer dying while the other keeps producing does not look
        // like that, and is what this catches.
        guard let latestEnd = coverageEndBySource.values.max() else {
            return true
        }
        let tailWindow = max(90, recordedSeconds * 0.10)
        return coverageEndBySource.values.allSatisfy {
            $0 >= latestEnd - tailWindow
        }
    }

    /// A failure the user cannot act on is only frightening. Naming the folder
    /// turns a lost meeting into one they still have.
    ///
    /// The caller must not pass the result of the call that failed. When
    /// `capture.stop()` is what threw, it returned nothing, and that is exactly
    /// the case this message exists for: the recording is on disk and the user
    /// has no way to know where. Discovery has to look at the disk instead.
    static func preservedRecordingNotice(for urls: [URL]) -> String {
        guard let first = urls.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            return ""
        }
        let folder = first.deletingLastPathComponent()
            .path(percentEncoded: false)
        return " Your recording was kept in \(folder) so you can try again."
    }

    private func startElapsedClock() {
        elapsedTask?.cancel()
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let activeElapsedStartedAt else { return }
                live.elapsed = accumulatedElapsed
                    + Date().timeIntervalSince(activeElapsedStartedAt)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func startAudioMeter() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let rise = targetAudioLevel > audioLevel ? 0.42 : 0.16
                var level = audioLevel + (targetAudioLevel - audioLevel) * rise
                // Levels arrive as a polled latest value instead of one hop
                // per buffer, so the decay and the fresh reading meet here.
                let fresh = isPaused
                    ? 0
                    : max(
                        capture.currentAudioLevel(for: .system),
                        capture.currentAudioLevel(for: .microphone)
                    )
                targetAudioLevel = max(targetAudioLevel * 0.76, fresh)
                if level < 0.008 { level = 0 }
                // Publishing now lands only on the leaf views observing
                // `live` (level ring, waveform, clocks, captions), but the
                // gate is still worth keeping:
                // writing the settled value every 80 ms through hours of
                // silence would redraw them for changes nobody can see. Only
                // real movement, or the drop to zero once it has finished
                // easing, publishes.
                if abs(level - audioLevel) >= 0.01 || (level == 0 && audioLevel != 0) {
                    live.audioLevel = level
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private func completePauseTransition() {
        pauseTransitionInFlight = false
        pauseTask = nil
        guard stopRequestedDuringPauseTransition else { return }
        stopRequestedDuringPauseTransition = false
        stopRecording()
    }

    private func startLiveCaptions() {
        liveStartupTask?.cancel()
        liveStartupTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await liveTranscriber.start(
                    localeIdentifier: localeIdentifier
                )
                guard !Task.isCancelled, phase.isRecording else {
                    await liveTranscriber.cancel()
                    return
                }
                liveTranscriptIsComplete = elapsed < 3
                capture.attachLiveTranscription(liveTranscriber)
                liveStartupTask = nil
            } catch {
                guard !Task.isCancelled else { return }
                liveTranscriptIsComplete = false
                liveCaptionNotice = "Live captions are taking a break. Nook will listen back to the saved audio."
                liveStartupTask = nil
            }
        }
    }

    private func receiveLiveTranscript(_ state: LiveTranscriptState) {
        live.liveTranscript = state
        noteStalledLiveTrack(in: state)
        scheduleLiveSummary(force: false)
    }

    /// How long the live summary waits between passes.
    ///
    /// Each refresh costs more as the meeting grows while adding less, so the
    /// interval backs off. Without it a long meeting spends most of its time
    /// summarizing itself and the panel never settles.
    static func liveSummaryInterval(forSegmentCount count: Int) -> TimeInterval {
        switch count {
        case ..<60: 28
        case ..<200: 60
        case ..<500: 120
        default: 240
        }
    }

    /// Starts a live summary pass, or queues one behind the pass already
    /// running.
    ///
    /// Every caption publish used to cancel the in-flight pass and restart its
    /// delay, so on a meeting where anybody was talking the summary never
    /// completed and `liveSummaryIsRefreshing`, set before the pass and
    /// cleared only on completion, span for the entire meeting. A running pass
    /// is now left alone; new material simply asks for the next one.
    private func scheduleLiveSummary(force: Bool) {
        guard phase.isRecording else { return }
        if force { liveSummaryForceRequested = true }
        let segments = liveTranscript.segments
        guard !segments.isEmpty, liveSummaryTask == nil else { return }

        let enoughNewMaterial = segments.count >= lastSummarizedSegmentCount + 4
        let enoughTimePassed = Date().timeIntervalSince(lastSummaryAt)
            >= Self.liveSummaryInterval(forSegmentCount: segments.count)
        guard liveSummaryForceRequested
            || (enoughNewMaterial && enoughTimePassed)
        else {
            return
        }

        let isForced = liveSummaryForceRequested
        liveSummaryForceRequested = false
        let fallbackTitle = activeDraft?.title ?? "Meeting so far"
        let snapshotCount = segments.count
        let previous = liveInsights
        let tail = SummaryService.liveTail(of: segments)
        let attention = SummaryAttention(
            myNotes: liveNotes,
            moments: liveMoments,
            transcript: segments
        )
        liveSummaryTask = Task { [weak self] in
            guard let self else { return }
            if !isForced {
                try? await Task.sleep(for: .milliseconds(900))
            }
            guard !Task.isCancelled, phase.isRecording else {
                liveSummaryTask = nil
                return
            }
            // The flag brackets the model call and nothing else, so the
            // spinner describes work that is actually happening.
            liveSummaryIsRefreshing = true
            let result = await summarizer.summarizeLive(
                tail: tail,
                fullTranscript: segments,
                previous: previous,
                fallbackTitle: fallbackTitle,
                attention: attention.isEmpty ? nil : attention
            )
            liveSummaryIsRefreshing = false
            liveSummaryTask = nil
            guard !Task.isCancelled, phase.isRecording else { return }
            liveInsights = result.insights
            if case .recording(_, let startedAt) = phase,
               !MeetingTitleGenerator.isFallbackTitle(
                    result.insights.title,
                    fallbackTitle: fallbackTitle
               ) {
                phase = .recording(
                    title: result.insights.title,
                    startedAt: startedAt
                )
            }
            liveSummaryUpdatedAt = Date()
            lastSummarizedSegmentCount = snapshotCount
            lastSummaryAt = Date()
            // Material that arrived while this pass ran gets its turn now,
            // rather than having interrupted it.
            if liveSummaryForceRequested
                || liveTranscript.segments.count > snapshotCount {
                scheduleLiveSummary(force: false)
            }
        }
    }

    /// Notices a caption track that has stopped producing while the other one
    /// keeps going.
    ///
    /// A recognizer can die without reporting anything, and the coverage check
    /// at stop time then decides the whole meeting. Clearing the flag while
    /// the meeting is still running means the saved-audio pass is already the
    /// plan by the time it matters. Judged on the audio clock the segments
    /// already carry, and only every few seconds, because this runs behind
    /// every caption update.
    private func noteStalledLiveTrack(in state: LiveTranscriptState) {
        guard liveTranscriptIsComplete else { return }
        let now = Date()
        guard now.timeIntervalSince(lastStallCheckAt) >= 15 else { return }
        lastStallCheckAt = now
        guard Self.liveTrackHasStalled(state.segments) else { return }
        liveTranscriptIsComplete = false
    }

    /// Whether one source's words stop far behind the other's.
    ///
    /// Silence on one side is ordinary, so only a gap longer than any natural
    /// pause counts, and a source that never produced a word at all is not
    /// judged: a meeting where nobody speaks into the microphone is normal.
    static func liveTrackHasStalled(_ segments: [TranscriptSegment]) -> Bool {
        let endBySource = Dictionary(grouping: segments, by: \.source)
            .mapValues { values in
                values.reduce(TimeInterval(0)) {
                    max($0, $1.startTime + $1.duration)
                }
            }
        guard endBySource.count > 1, let newest = endBySource.values.max() else {
            return false
        }
        return endBySource.values.contains { newest - $0 > stalledTrackGap }
    }

    static let stalledTrackGap: TimeInterval = 300

    func setPreviewState(
        phase: MeetingPhase,
        elapsed: TimeInterval,
        liveTranscript: LiveTranscriptState,
        audioLevel: Double,
        panelMode: MeetingPanelMode? = nil,
        liveInsights: MeetingInsights? = nil,
        liveNotes: String? = nil,
        isPaused: Bool = false
    ) {
        self.phase = phase
        live.elapsed = elapsed
        live.liveTranscript = liveTranscript
        live.audioLevel = audioLevel
        self.isPaused = isPaused
        if let panelMode { self.panelMode = panelMode }
        self.liveInsights = liveInsights
        if let liveNotes { self.liveNotes = liveNotes }
    }

    private func discardCancelledMeeting(
        draft: MeetingDraft,
        additionalURLs: [URL]
    ) async {
        liveStartupTask?.cancel()
        liveStartupTask = nil
        liveSummaryTask?.cancel()
        liveSummaryTask = nil
        liveSummaryIsRefreshing = false
        liveSummaryForceRequested = false
        invalidateSummaryProgress()
        elapsedTask?.cancel()
        meterTask?.cancel()

        var files = additionalURLs
        if capture.isCapturing,
           let capturedURLs = try? await capture.stop() {
            files.append(contentsOf: capturedURLs)
        }
        await liveTranscriber.cancel()
        let cleanupFailures = RecordingArtifactCleanup.removeArtifacts(
            for: draft,
            additionalURLs: files
        )

        recordingStartTask = nil
        processingTask = nil
        activeDraft = nil
        pendingStartRequest = nil
        requiredPermission = nil
        processingCancellationRequested = false
        processingOwnsAttachedScaffold = false
        stopRequestedDuringPauseTransition = false
        live.elapsed = 0
        accumulatedElapsed = 0
        activeElapsedStartedAt = nil
        isPaused = false
        pauseTransitionInFlight = false
        pauseTask = nil
        live.audioLevel = 0
        targetAudioLevel = 0
        liveCaptionNotice = nil
        live.liveTranscript = .empty
        liveNotes = ""
        liveInsights = nil
        liveSummaryUpdatedAt = nil
        topPanelHidden = false
        phase = cleanupFailures.isEmpty
            ? .idle
            : .failed(
                "Nook stopped the meeting but could not remove every temporary recording file."
                    + Self.cleanupNotice(for: cleanupFailures)
            )
    }

    #if DEBUG
    var hasDeferredStopForTesting: Bool {
        stopRequestedDuringPauseTransition
    }

    func setPauseTransitionForTesting(_ inFlight: Bool) {
        pauseTransitionInFlight = inFlight
    }

    func completePauseTransitionForTesting() {
        completePauseTransition()
    }

    var liveSummaryIsRunningForTesting: Bool {
        liveSummaryTask != nil
    }

    var liveSummaryForceIsQueuedForTesting: Bool {
        liveSummaryForceRequested
    }

    func receiveLiveTranscriptForTesting(_ state: LiveTranscriptState) {
        receiveLiveTranscript(state)
    }

    var liveTranscriptIsCompleteForTesting: Bool {
        liveTranscriptIsComplete
    }

    func setLiveTranscriptCompleteForTesting(_ complete: Bool) {
        liveTranscriptIsComplete = complete
        lastStallCheckAt = .distantPast
    }

    func setSummaryProgressForTesting(_ progress: SummaryProgress?) {
        summaryProgress = progress
    }

    @discardableResult
    func startDraftForTesting() -> UUID {
        let id = UUID()
        activeDraft = MeetingDraft(
            id: id,
            title: "Review",
            sourceApp: "Manual",
            startedAt: Date(),
            recordingURL: store.recordingsDirectory()
                .appendingPathComponent("\(id.uuidString).mp4")
        )
        return id
    }

    func clearDraftForTesting() {
        activeDraft = nil
    }

    var liveNotesSaveForTesting: Task<Void, Never>? {
        liveNotesSaveTask
    }
    #endif

    // MARK: - Live notes on disk

    /// Writes the meeting's typed notes beside its recording, shortly after
    /// typing stops.
    ///
    /// Debounced rather than written per keystroke, and only while a meeting
    /// is in flight: with no draft there is no recording for the notes to be
    /// recovered alongside, so there is nothing to keep them for. The file
    /// lives inside `.recordings`, which means the same artifact cleanup that
    /// removes the capture removes this too, and the same folder permissions
    /// cover it.
    private func scheduleLiveNotesSave() {
        guard let draft = activeDraft else { return }
        // Settings can change the notes folder during a meeting. The capture
        // and its resumed segments stay at their original destination, so its
        // typed notes must stay there too for recovery and cleanup to find.
        let url = Self.liveNotesURL(for: draft)
        let body = liveNotes
        liveNotesSaveTask?.cancel()
        liveNotesSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            // Cancelled means the meeting ended and its artifacts have been
            // dealt with; gone means the app is going, and there is no
            // meeting left for these to be recovered alongside.
            guard !Task.isCancelled, let self,
                  self.activeDraft?.id == draft.id,
                  self.activeDraft?.recordingURL == draft.recordingURL
            else { return }
            Self.writeLiveNotes(body, to: url)
        }
    }

    nonisolated static func liveNotesURL(for draft: MeetingDraft) -> URL {
        liveNotesURL(
            for: draft.id,
            in: draft.recordingURL.deletingLastPathComponent()
        )
    }

    /// Where a meeting's typed notes are held while it runs.
    ///
    /// Named for the meeting's own identifier so recovery, which knows only
    /// that, can find them, and so artifact cleanup recognises them as
    /// belonging to this meeting rather than to `.recordings` at large.
    nonisolated static func liveNotesURL(
        for id: UUID,
        in directory: URL
    ) -> URL {
        directory.appendingPathComponent("\(id.uuidString).notes.txt")
    }

    nonisolated static func writeLiveNotes(_ body: String, to url: URL) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Emptying the field is the user deleting these words. Leaving a
            // stale file behind would put them back on recovery.
            try? FileManager.default.removeItem(at: url)
            return
        }
        // Whitespace-only input still means the field was cleared. Otherwise
        // keep the user's exact bytes, including indentation and Unicode form.
        guard (try? Data(body.utf8).write(to: url, options: .atomic))
            != nil
        else {
            // The notes are still in the window and still go into the note
            // when the meeting finishes normally. This file only covers the
            // finish that never comes, so a failure here is not worth
            // interrupting a meeting over.
            return
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    /// The notes typed during a meeting that never became a note, if any.
    nonisolated static func recoverableLiveNotes(
        for id: UUID,
        in directory: URL
    ) -> String {
        let url = liveNotesURL(for: id, in: directory)
        guard let body = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "" : body
    }

    private static func cleanupNotice(for urls: [URL]) -> String {
        guard !urls.isEmpty else { return "" }
        return " Remove these files from the .recordings folder: "
            + urls.map(\.lastPathComponent).sorted().joined(separator: ", ")
            + "."
    }
}

/// Deletes only artifacts owned by one meeting UUID. This intentionally does
/// not sweep `.recordings`: retained audio and another meeting's recovery files
/// must survive cleanup of the current lifecycle.
enum RecordingArtifactCleanup {
    static func artifactURLs(
        for draft: MeetingDraft,
        additionalURLs: [URL] = [],
        fileManager: FileManager = .default
    ) -> Set<URL> {
        let directory = draft.recordingURL
            .deletingLastPathComponent()
            .standardizedFileURL
        let stem = draft.recordingURL
            .deletingPathExtension()
            .lastPathComponent

        var candidates = Set(
            additionalURLs
                .map(\.standardizedFileURL)
                .filter { isOwnedArtifact($0, directory: directory, stem: stem) }
        )
        candidates.insert(draft.recordingURL.standardizedFileURL)
        candidates.insert(
            draft.recordingURL
                .deletingPathExtension()
                .appendingPathExtension("m4a")
                .standardizedFileURL
        )
        // The typed notes are held beside the capture for the length of the
        // meeting. Once the note exists they are inside it, so leaving the
        // file behind would litter the folder with a second copy nobody
        // reads and nothing removes.
        candidates.insert(
            MeetingCoordinator.liveNotesURL(for: draft)
                .standardizedFileURL
        )

        if let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) {
            candidates.formUnion(
                contents
                    .map(\.standardizedFileURL)
                    .filter { isOwnedArtifact($0, directory: directory, stem: stem) }
            )
        }
        return candidates
    }

    @discardableResult
    static func removeArtifacts(
        for draft: MeetingDraft,
        additionalURLs: [URL] = [],
        preserving preservedURLs: Set<URL> = [],
        fileManager: FileManager = .default
    ) -> [URL] {
        let preserved = Set(preservedURLs.map(\.standardizedFileURL))
        var failures: [URL] = []
        for url in artifactURLs(
            for: draft,
            additionalURLs: additionalURLs,
            fileManager: fileManager
        ) where !preserved.contains(url) && fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                failures.append(url)
            }
        }
        return failures
    }

    private static func isOwnedArtifact(
        _ url: URL,
        directory: URL,
        stem: String
    ) -> Bool {
        guard url.deletingLastPathComponent().standardizedFileURL == directory else {
            return false
        }
        let filename = url.lastPathComponent
        return filename == "\(stem).mp4"
            || filename == "\(stem).m4a"
            || filename == "\(stem).notes.txt"
            || (filename.hasPrefix("\(stem).part-") && url.pathExtension == "mp4")
    }
}

private struct PendingStartRequest {
    let title: String
    let sourceApp: String
    let attachment: LibraryNoteIdentity?
}

private enum PermissionResumeKey {
    static let shouldResume = "resumeRecordingAfterPermission"
    static let title = "resumeRecordingAfterPermissionTitle"
    static let sourceApp = "resumeRecordingAfterPermissionSource"
    static let attachedNoteID = "resumeRecordingAfterPermissionNoteID"
    static let attachedNotePath = "resumeRecordingAfterPermissionNotePath"
}
