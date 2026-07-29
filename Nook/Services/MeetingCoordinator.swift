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
    }

    var menuBarSymbol: String {
        switch self {
        case .recording:
            "record.circle.fill"
        case .processing:
            "waveform.badge.magnifyingglass"
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
        case .summary: "So far"
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
    private var liveStartupTask: Task<Void, Never>?
    private var liveSummaryTask: Task<Void, Never>?
    private var dismissedDetection: DetectedMeeting?
    private var targetAudioLevel = 0.0
    private var liveTranscriptIsComplete = false
    private var lastSummarizedSegmentCount = 0
    private var lastSummaryAt = Date.distantPast
    private var pendingStartRequest: PendingStartRequest?
    private var accumulatedElapsed: TimeInterval = 0
    private var activeElapsedStartedAt: Date?

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
    }

    func startDetectedMeeting() {
        guard case .detected(let detection) = phase else { return }
        startRecording(title: detection.suggestedTitle, sourceApp: detection.appName)
    }

    func startManualMeeting() {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE h:mm a"
        startRecording(
            title: "Meeting — \(formatter.string(from: Date()))",
            sourceApp: "Manual"
        )
    }

    func stopRecording() {
        guard phase.isRecording, processingTask == nil,
              !pauseTransitionInFlight
        else {
            return
        }
        elapsedTask?.cancel()
        meterTask?.cancel()
        onRecordingStopped?()
        phase = .processing(.preparing)
        onPresentationRequested?()
        processingTask = Task { [weak self] in
            await self?.finishRecording()
        }
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

        Task { [weak self] in
            guard let self else { return }
            do {
                try await capture.pause()
                liveCaptionNotice = "Paused — Nook is not saving or transcribing audio."
            } catch {
                isPaused = false
                activeElapsedStartedAt = Date()
                startElapsedClock()
                liveCaptionNotice = "Nook couldn’t pause this recording. Capture is still active."
            }
            pauseTransitionInFlight = false
        }
    }

    func resumeRecording() {
        guard phase.isRecording, isPaused, !pauseTransitionInFlight else {
            return
        }
        pauseTransitionInFlight = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try capture.resume()
                isPaused = false
                activeElapsedStartedAt = Date()
                startElapsedClock()
                liveCaptionNotice = nil
            } catch {
                liveCaptionNotice = "Nook couldn’t resume yet. Your completed audio remains safe."
            }
            pauseTransitionInFlight = false
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
        showLiveCaptions = true
        if mode == .summary {
            refreshLiveSummary()
        } else if mode == .notes {
            onPanelInteractionRequested?()
        }
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
        accumulatedElapsed = 0
        activeElapsedStartedAt = nil
        audioLevel = 0
        targetAudioLevel = 0
        phase = .processing(.preparing)
        onPresentationRequested?()

        Task { [weak self] in
            guard let self else { return }
            let updateLevel: @MainActor (
                Double,
                TranscriptSegment.Source
            ) -> Void = { [weak self] level, _ in
                guard let self else { return }
                self.targetAudioLevel = max(self.targetAudioLevel, level)
            }

            do {
                try await capture.requestPermissions()
                try await SpeechAssets.requestAuthorization()
                try await capture.start(
                    to: url,
                    permissionsAreReady: true,
                    onAudioLevel: updateLevel
                )
                pendingStartRequest = nil
                requiredPermission = nil
                phase = .recording(title: title, startedAt: draft.startedAt)
                activeElapsedStartedAt = Date()
                startElapsedClock()
                startAudioMeter()
                startLiveCaptions()
            } catch {
                activeDraft = nil
                requiredPermission = Self.permissionRequired(for: error)
                if requiredPermission == nil {
                    pendingStartRequest = nil
                }
                phase = .failed(error.localizedDescription)
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
        do {
            liveStartupTask?.cancel()
            liveStartupTask = nil
            liveSummaryTask?.cancel()
            liveSummaryTask = nil
            liveSummaryIsRefreshing = false
            let recordingURLs = try await capture.stop()
            let liveSegments = await liveTranscriber.stop()
            phase = .processing(.preparing)
            try await AudioExtractor.extractAudio(
                from: recordingURLs,
                to: audioURL
            )

            phase = .processing(.refining)
            let rawTranscript: [TranscriptSegment]
            if liveTranscriptIsComplete,
               liveSegments.reduce(0, { $0 + $1.text.count }) >= 40 {
                rawTranscript = liveSegments
            } else {
                phase = .processing(.transcribing)
                rawTranscript = try await transcriber.transcribe(
                    audioURL: audioURL,
                    localeIdentifier: localeIdentifier
                )
            }
            let transcript = TranscriptAssembler.coalesce(rawTranscript)

            phase = .processing(.summarizing)
            let insights = await summarizer.summarize(
                transcript: transcript,
                fallbackTitle: draft.title
            )

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

            if !keepAudio {
                try? FileManager.default.removeItem(at: audioURL)
            }
            for recordingURL in recordingURLs {
                try? FileManager.default.removeItem(at: recordingURL)
            }

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
            phase = .completed(saved.title)
            onPresentationRequested?()
        } catch {
            liveStartupTask?.cancel()
            liveStartupTask = nil
            liveSummaryTask?.cancel()
            liveSummaryTask = nil
            liveSummaryIsRefreshing = false
            await liveTranscriber.cancel()
            activeDraft = nil
            processingTask = nil
            elapsed = 0
            accumulatedElapsed = 0
            activeElapsedStartedAt = nil
            isPaused = false
            pauseTransitionInFlight = false
            audioLevel = 0
            phase = .failed(error.localizedDescription)
            onPresentationRequested?()
        }
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
                audioLevel += (targetAudioLevel - audioLevel) * rise
                targetAudioLevel *= 0.76
                if audioLevel < 0.008 { audioLevel = 0 }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
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
