import AppKit
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

@MainActor
final class MeetingCoordinator: ObservableObject {
    @Published private(set) var phase: MeetingPhase = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var liveTranscript = LiveTranscriptState.empty
    @Published private(set) var liveInsights: MeetingInsights?
    @Published private(set) var liveSummaryIsRefreshing = false
    @Published private(set) var liveSummaryUpdatedAt: Date?
    @Published var liveNotes = ""
    @Published private(set) var liveNotesDetached = false
    @Published private(set) var audioLevel = 0.0
    @Published private(set) var isPaused = false
    @Published private(set) var pauseTransitionInFlight = false
    @Published private(set) var liveCaptionNotice: String?
    @Published private(set) var requiredPermission: NookPermission?
    @Published private(set) var topPanelHidden = false
    @Published var localeIdentifier: String {
        didSet { UserDefaults.standard.set(localeIdentifier, forKey: "transcriptionLocale") }
    }
    @Published var keepAudio: Bool {
        didSet { UserDefaults.standard.set(keepAudio, forKey: "keepAudio") }
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
    private let capture = CaptureService()
    private let transcriber = TranscriptionService()
    private let liveTranscriber = LiveTranscriptionService()
    private let summarizer = SummaryService()
    private var activeDraft: MeetingDraft?
    private var elapsedTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var recordingStartTask: Task<Void, Never>?
    private var liveStartupTask: Task<Void, Never>?
    private var liveSummaryTask: Task<Void, Never>?
    private var pauseTask: Task<Void, Never>?
    private var dismissedDetection: DetectedMeeting?
    private var targetAudioLevel = 0.0
    private var liveTranscriptIsComplete = false
    private var lastSummarizedSegmentCount = 0
    private var lastSummaryAt = Date.distantPast
    private var pendingStartRequest: PendingStartRequest?
    private var accumulatedElapsed: TimeInterval = 0
    private var activeElapsedStartedAt: Date?
    private var processingCancellationRequested = false
    /// A meeting can end while ScreenCaptureKit is finalizing a pause or adding
    /// the resumed output. Remember that stop request and run it as soon as the
    /// transition becomes terminal instead of silently discarding it.
    private var stopRequestedDuringPauseTransition = false

    init(store: MarkdownStore, detector: MeetingDetector) {
        self.store = store
        self.detector = detector
        self.localeIdentifier = UserDefaults.standard.string(forKey: "transcriptionLocale")
            ?? Locale.current.identifier
        self.keepAudio = UserDefaults.standard.bool(forKey: "keepAudio")
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
        onRecordingStopped?()
        topPanelHidden = false
        processingCancellationRequested = false
        phase = .processing(.preparing)
        NookEventLog.write(.meetingStopStarted)
        onPresentationRequested?()
        processingTask = Task { [weak self] in
            await self?.finishRecording()
        }
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

    var canCancelProcessing: Bool {
        guard case .processing(let step) = phase,
              step != .discarding,
              activeDraft != nil
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
        alert.informativeText = """
            Processing has not finished, so nothing has been saved yet. \
            Discarding deletes the audio permanently.
            """
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

    func pauseRecording() {
        guard phase.isRecording, !isPaused, !pauseTransitionInFlight else {
            return
        }
        pauseTransitionInFlight = true
        accumulatedElapsed = elapsed
        activeElapsedStartedAt = nil
        elapsedTask?.cancel()
        isPaused = true
        audioLevel = 0
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

    @discardableResult
    func resumePendingStartAfterPermission() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: PermissionResumeKey.shouldResume) else {
            return false
        }

        let title = defaults.string(forKey: PermissionResumeKey.title)
        let sourceApp = defaults.string(forKey: PermissionResumeKey.sourceApp)
        defaults.removeObject(forKey: PermissionResumeKey.shouldResume)
        defaults.removeObject(forKey: PermissionResumeKey.title)
        defaults.removeObject(forKey: PermissionResumeKey.sourceApp)

        guard let title, let sourceApp else { return false }
        startRecording(title: title, sourceApp: sourceApp)
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

    private func handleDetection(_ detection: DetectedMeeting) {
        guard activeDraft == nil, processingTask == nil, dismissedDetection != detection else { return }
        phase = .detected(detection)
        onPresentationRequested?()
        onMeetingNotificationRequested?(detection)
    }

    private func handleMeetingEnded() {
        dismissedDetection = nil
        if phase.isRecording {
            stopRecording()
        } else if case .detected = phase {
            phase = .idle
        }
    }

    private func startRecording(title: String, sourceApp: String) {
        guard activeDraft == nil, processingTask == nil else { return }
        pendingStartRequest = PendingStartRequest(
            title: title,
            sourceApp: sourceApp
        )
        requiredPermission = nil
        let id = UUID()
        let url = store.recordingsDirectory().appendingPathComponent("\(id.uuidString).mp4")
        let draft = MeetingDraft(
            id: id,
            title: title,
            sourceApp: sourceApp,
            startedAt: Date(),
            recordingURL: url
        )
        activeDraft = draft
        liveTranscript = .empty
        liveInsights = nil
        liveSummaryUpdatedAt = nil
        liveSummaryIsRefreshing = false
        liveNotes = ""
        lastSummarizedSegmentCount = 0
        lastSummaryAt = .distantPast
        liveCaptionNotice = nil
        liveTranscriptIsComplete = false
        isPaused = false
        pauseTransitionInFlight = false
        topPanelHidden = false
        processingCancellationRequested = false
        stopRequestedDuringPauseTransition = false
        accumulatedElapsed = 0
        activeElapsedStartedAt = nil
        audioLevel = 0
        targetAudioLevel = 0
        phase = .processing(.preparing)
        onPresentationRequested?()

        recordingStartTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await capture.requestPermissions()
                try Task.checkCancellation()
                try await SpeechAssets.requestAuthorization()
                try Task.checkCancellation()
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
                startElapsedClock()
                startAudioMeter()
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
        startRecording(title: request.title, sourceApp: request.sourceApp)
    }

    private func persistPendingStartRequest() {
        guard let request = pendingStartRequest else { return }
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: PermissionResumeKey.shouldResume)
        defaults.set(request.title, forKey: PermissionResumeKey.title)
        defaults.set(request.sourceApp, forKey: PermissionResumeKey.sourceApp)
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
            let liveSegments = await liveTranscriber.stop()
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

            phase = .processing(.summarizing)
            let insights = await summarizer.summarize(
                transcript: transcript,
                fallbackTitle: draft.title
            )
            try Task.checkCancellation()

            phase = .processing(.saving)
            let note = MeetingNote(
                id: draft.id,
                title: insights.title,
                startedAt: draft.startedAt,
                endedAt: Date(),
                sourceApp: draft.sourceApp,
                summary: insights.summary,
                keyPoints: insights.keyPoints,
                decisions: insights.decisions,
                actionItems: insights.actionItems,
                personalNotes: personalNotes,
                transcript: transcript
            )
            let saved = try store.save(note)

            let cleanupFailures = RecordingArtifactCleanup.removeArtifacts(
                for: draft,
                additionalURLs: recordingURLs + [audioURL],
                preserving: keepAudio ? Set([audioURL]) : []
            )

            activeDraft = nil
            processingTask = nil
            elapsed = 0
            accumulatedElapsed = 0
            activeElapsedStartedAt = nil
            isPaused = false
            pauseTransitionInFlight = false
            audioLevel = 0
            liveCaptionNotice = nil
            liveNotes = ""
            liveInsights = nil
            liveSummaryUpdatedAt = nil
            topPanelHidden = false
            processingCancellationRequested = false
            stopRequestedDuringPauseTransition = false
            if cleanupFailures.isEmpty {
                phase = .completed(saved.title)
                NookEventLog.write(.meetingSaved)
            } else {
                phase = .failed(
                    "Your meeting note was saved, but Nook could not remove every temporary recording file."
                        + Self.cleanupNotice(for: cleanupFailures)
                )
            }
            onPresentationRequested?()
        } catch {
            if Task.isCancelled || processingCancellationRequested {
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
            await liveTranscriber.cancel()
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
            elapsed = 0
            accumulatedElapsed = 0
            activeElapsedStartedAt = nil
            isPaused = false
            pauseTransitionInFlight = false
            audioLevel = 0
            processingCancellationRequested = false
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
        return coverageEndBySource.values.allSatisfy {
            $0 >= recordedSeconds * 0.75
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
                elapsed = accumulatedElapsed
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
                // Publishing writes objectWillChange for every observer of the
                // coordinator, panel and menus included. Writing the settled
                // value every 80 ms through hours of silence invalidated all
                // of them for output that never changed; only real movement,
                // or the drop to zero once it has finished easing, publishes.
                if abs(level - audioLevel) >= 0.01 || (level == 0 && audioLevel != 0) {
                    audioLevel = level
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
        liveTranscript = state
        scheduleLiveSummary(force: false)
    }

    private func scheduleLiveSummary(force: Bool) {
        guard phase.isRecording else { return }
        let segments = liveTranscript.segments
        guard !segments.isEmpty else { return }

        let enoughNewMaterial = segments.count >= lastSummarizedSegmentCount + 4
        let enoughTimePassed = Date().timeIntervalSince(lastSummaryAt) >= 28
        guard force || (enoughNewMaterial && enoughTimePassed) else { return }

        liveSummaryTask?.cancel()
        liveSummaryIsRefreshing = true
        let fallbackTitle = activeDraft?.title ?? "Meeting so far"
        let snapshotCount = segments.count
        liveSummaryTask = Task { [weak self] in
            guard let self else { return }
            if !force {
                try? await Task.sleep(for: .milliseconds(900))
            }
            guard !Task.isCancelled else { return }
            let insights = await summarizer.summarize(
                transcript: segments,
                fallbackTitle: fallbackTitle
            )
            guard !Task.isCancelled, phase.isRecording else { return }
            liveInsights = insights
            if case .recording(_, let startedAt) = phase,
               !MeetingTitleGenerator.isFallbackTitle(
                    insights.title,
                    fallbackTitle: fallbackTitle
               ) {
                phase = .recording(
                    title: insights.title,
                    startedAt: startedAt
                )
            }
            liveSummaryUpdatedAt = Date()
            liveSummaryIsRefreshing = false
            lastSummarizedSegmentCount = snapshotCount
            lastSummaryAt = Date()
            liveSummaryTask = nil
        }
    }

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
        self.elapsed = elapsed
        self.liveTranscript = liveTranscript
        self.audioLevel = audioLevel
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
        stopRequestedDuringPauseTransition = false
        elapsed = 0
        accumulatedElapsed = 0
        activeElapsedStartedAt = nil
        isPaused = false
        pauseTransitionInFlight = false
        pauseTask = nil
        audioLevel = 0
        targetAudioLevel = 0
        liveCaptionNotice = nil
        liveTranscript = .empty
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
    #endif

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
            || (filename.hasPrefix("\(stem).part-") && url.pathExtension == "mp4")
    }
}

private struct PendingStartRequest {
    let title: String
    let sourceApp: String
}

private enum PermissionResumeKey {
    static let shouldResume = "resumeRecordingAfterPermission"
    static let title = "resumeRecordingAfterPermissionTitle"
    static let sourceApp = "resumeRecordingAfterPermissionSource"
}
