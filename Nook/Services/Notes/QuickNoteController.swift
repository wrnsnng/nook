import AppKit
import Combine
import Foundation
import SwiftUI

/// A note captured by speaking with no text field in the way.
///
/// The point is that nothing has to be open first — no app, no file, no window.
/// Hold the shortcut anywhere, say the thing, and it lands somewhere it can be
/// found again. It saves as ordinary Markdown into the same folder as meetings,
/// so it is searchable in the library and readable by anything else on the Mac.
@MainActor
final class QuickNoteController: ObservableObject {
    @Published var text = "" {
        didSet {
            guard !text.utf8.elementsEqual(oldValue.utf8) else { return }
            textRevision &+= 1
            voiceCorrection = nil
            voiceUndo = nil
            lastDictatedEdit = nil
            voiceStatus = nil
            if isShowingEmptyDraftValidation,
               text.unicodeScalars.contains(where: {
                   !CharacterSet.whitespacesAndNewlines.contains($0)
               }) {
                // Undo/Redo and typing can resolve this validation before the
                // next autosave. A real save failure still belongs to the file.
                message = nil
                hasUnsavedFailure = false
                hasUnsavedEdits = true
            }
            checkpointEdit()
            scheduleTextAnalysis()
        }
    }
    /// A count belongs to one exact revision. Hide it while the worker catches
    /// up rather than displaying the previous note's total. Statistics must
    /// never delay typing, checkpointing, saving, or safe discard decisions.
    @Published private(set) var wordCount: Int? = 0
    /// Never offer a task parsed from an earlier text revision. Like the word
    /// count, suggestions are advisory and may catch up after the words save.
    @Published private(set) var taskSuggestion: QuickCaptureTaskParser.Suggestion?
    @Published private(set) var isPresenting = false
    @Published var filingRequest: QuickNoteFilingRequest?
    @Published private(set) var voiceCorrection: VoiceCorrectionProposal?
    @Published private(set) var voiceStatus: String?
    @Published private(set) var isReviewingVoiceCorrection = false
    @Published private var voiceUndo: DictatedEdit?
    private var lastDictatedEdit: DictatedEdit?
    private var voicePresentationID: UUID?
    private var voiceLibraryGeneration: Int?
    private let announceVoiceStatus: (@MainActor (String) -> Void)?
    /// Only an explicit presentation requests the keyboard. Routine text,
    /// statistics, and toolbar updates must leave the user's chosen focus alone.
    @Published private(set) var editorFocusToken = 0
    @Published private(set) var isWorking = false
    @Published private(set) var message: String? {
        didSet {
            // Any replacement message supersedes the empty-text validation,
            // including a failed discard or an actual filesystem error.
            isShowingEmptyDraftValidation = false
        }
    }
    private var isShowingEmptyDraftValidation = false
    @Published private(set) var recoveryWarning: String?
    /// Filing can succeed while removing the earlier standalone copy fails.
    /// Keep that outcome independently of later typing and successful saves.
    @Published private(set) var filingCompletionMessage: String?
    @Published private(set) var lastSavedAt: Date?
    /// Whether edits have landed since the last save, so the status line can
    /// say "Saved" only while it is true.
    @Published private(set) var hasUnsavedEdits = false
    /// Set when a save failed and the words exist nowhere but this window.
    ///
    /// While it is set the pad refuses to close and refuses to start a new
    /// note over the top of these ones. Closing on a failed save was silent
    /// data loss of the worst kind here: the pad is usually the only copy of
    /// something that was said out loud a second ago.
    @Published private(set) var hasUnsavedFailure = false

    /// Nook keeping the user's own words is a decision, not a failure.
    ///
    /// The pad shows one message line, and drawing this one in warning colours
    /// told people something had broken when the guard had worked exactly as
    /// intended. Everything else that reaches `message` is a failure.
    nonisolated static let keptYourOwnWordsNotice =
        "The rewrite didn't stay close to your note, so your own words were kept."

    var messageIsAdvisory: Bool {
        message == Self.keptYourOwnWordsNotice
    }
    /// Which action is running, so its own button can show it rather than a
    /// spinner floating somewhere else in the bar.
    @Published private(set) var runningAction: NoteAction?
    @Published private(set) var runningEngine: NoteAssistantEngine?
    @Published private(set) var isStoppingAssistant = false
    @Published private(set) var isPreparingForTermination = false
    @Published private(set) var availableEngines: [NoteAssistantEngine] = []

    @Published private(set) var engine: NoteAssistantEngine {
        didSet {
            defaults.set(engine.rawValue, forKey: Keys.engine)
        }
    }

    /// Hands-free capture: after each spoken chunk lands, listening starts
    /// again by itself until the pad is closed, the toggle turns off, or the
    /// dictation shortcut is pressed to stop.
    @Published var isContinuous: Bool {
        didSet {
            defaults.set(isContinuous, forKey: Keys.continuous)
        }
    }

    /// Aim for toolbar commands that type at the cursor, such as inserting a
    /// checklist line. The editor wires this to its text view when created.
    let editorPort = TextViewInsertionPort()

    /// Chooses an engine, asking first if it means sending notes off the Mac.
    ///
    /// Deliberately a modal decision rather than a tooltip or a footnote. Every
    /// other part of Nook promises that nothing leaves the machine, and the one
    /// place that stops being true should be impossible to enable without
    /// having read what it means.
    func selectEngine(_ engine: NoteAssistantEngine) {
        if engine == .onDevice, runningEngine?.leavesTheMac == true {
            requestAssistantStop()
        }
        guard engine != self.engine else { return }
        guard engine.leavesTheMac, !hasConsented(to: engine) else {
            setSelectedEngine(engine)
            return
        }
        guard confirmSending(to: engine) else { return }
        defaults.set(true, forKey: Keys.consent(engine))
        setSelectedEngine(engine)
    }

    func hasConsented(to engine: NoteAssistantEngine) -> Bool {
        guard engine.leavesTheMac else { return true }
        return defaults.bool(forKey: Keys.consent(engine))
    }

    /// Forgets a previous agreement, so the explanation is shown again.
    func revokeConsent(for engine: NoteAssistantEngine) {
        defaults.removeObject(forKey: Keys.consent(engine))
        if runningEngine == engine { requestAssistantStop() }
        if self.engine == engine {
            setSelectedEngine(.onDevice)
        }
    }

    private func setSelectedEngine(_ engine: NoteAssistantEngine) {
        self.engine = engine
        if let runningEngine, runningEngine != engine { requestAssistantStop() }
    }

    var isSelectedAssistantAvailable: Bool { availableEngines.contains(engine) }

    /// One installed alternative is still a choice when the selected local
    /// engine is unavailable. Never choose an external provider without consent.
    var canChooseAssistant: Bool {
        !availableEngines.isEmpty
            && (availableEngines.count > 1 || !isSelectedAssistantAvailable)
    }

    var canRunAction: Bool {
        !text.isEmpty && !isWorking && !isPreparingForTermination && isSelectedAssistantAvailable
            && hasConsented(to: engine)
    }

    /// The selected assistant describes the next action. An existing external
    /// run keeps its disclosure until its operation has actually returned.
    var outboundEngine: NoteAssistantEngine? {
        if let runningEngine, runningEngine.leavesTheMac { return runningEngine }
        return engine.leavesTheMac ? engine : nil
    }

    var selectedAssistantDescription: String {
        isSelectedAssistantAvailable
            ? engine.detail
            : "\(engine.toolName) is unavailable. Choose an available assistant."
    }

    var outboundMessage: String {
        if let running = runningEngine, running.leavesTheMac {
            if isStoppingAssistant {
                return running == .codex
                    ? "Stopping Codex. Text may have reached OpenAI; file access may continue."
                    : "Stopping Claude. Text may already have reached Anthropic."
            }
            return running == .codex
                ? "Codex is running. Text goes to OpenAI; it can read local files."
                : "Claude is running. This note is sent to Anthropic."
        }
        guard let outboundEngine, let provider = outboundEngine.provider else { return "" }
        return outboundEngine == .codex
            ? "Actions send to OpenAI. Codex can read local files."
            : "Actions send this note to \(provider)."
    }

    var actionStatusDescription: String {
        if let action = runningAction, let engine = runningEngine {
            return isStoppingAssistant
                ? "Stopping \(action.title), using \(engine.title)."
                : "\(action.title) is running, using \(engine.title)."
        }
        if isPreparingForTermination { return "Preparing to quit Nook." }
        if !isSelectedAssistantAvailable { return selectedAssistantDescription }
        if text.isEmpty { return "Add words to use note actions." }
        return "Using \(engine.title)"
    }

    var actionAvailabilityHint: String {
        if isStoppingAssistant {
            return "Your words are kept. Waiting for the assistant to finish stopping. Editing and saving remain available."
        }
        if isWorking {
            return "Wait for this action to finish before starting another. You can keep editing or save and close."
        }
        if isPreparingForTermination {
            return "Note actions are unavailable while Nook prepares to quit. Editing and saving remain available."
        }
        if !isSelectedAssistantAvailable {
            return "Use Choose an assistant to review available options. Editing and saving remain available."
        }
        if text.isEmpty { return "Type or dictate a note first." }
        return "Choose an action to change or add to this note."
    }

    private func confirmSending(to engine: NoteAssistantEngine) -> Bool {
        guard let provider = engine.provider else { return true }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Send your notes to \(provider)?"
        alert.informativeText = """
        Nook keeps everything on this Mac. Choosing \(engine.title) is the one \
        exception.

        When you run an action, the full text of that note is sent to \
        \(provider) by \(engine.toolName), using the subscription you are \
        already signed into there. It is handled under \(provider)'s terms and \
        privacy policy, not Nook's.

        Nothing is sent until you run an action. Nook passes the current \
        note without attaching recordings, meetings, or other notes.
        """
        if engine == .codex {
            alert.informativeText += "\n\n" + """
            Codex runs in read-only mode, but it can still read other files \
            it can access on this Mac. Information it reads may also be sent \
            to OpenAI. Nook does not confine Codex to this note.
            """
        }
        alert.addButton(withTitle: "Send Notes to \(provider)")
        alert.addButton(withTitle: "Keep Everything On This Mac")
        // The safe option is the default, so a reflexive Return keeps the
        // private behaviour rather than agreeing to the exception.
        alert.buttons.last?.keyEquivalent = "\r"
        alert.buttons.first?.keyEquivalent = ""

        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Whether the note window is the one the user is actually typing in.
    ///
    /// Distinct from `isPresenting`, which only says the window exists. The
    /// note floats and deliberately stays open when you switch apps, so a note
    /// left open in the corner must not keep claiming dictation that belongs to
    /// whatever text field now has focus.
    var isFrontmost: Bool {
        panel?.isKeyWindow == true
    }

    var isDictationSurfaceActive: Bool {
        isFrontmost && !isReviewingVoiceCorrection && filingRequest == nil
    }

    /// Empty visible text can still own an autosaved note after Undo. Discard
    /// removes that owned file, while a new pad with no text has nothing to do.
    var canDiscard: Bool {
        savedNote != nil || !text.isEmpty
    }

    private let store: MarkdownStore
    private let defaults: UserDefaults
    private let recovery: DraftJournal?
    private var recoveryObservation: AnyCancellable?
    private var libraryObservation: AnyCancellable?
    private let openFilingLibrary: @MainActor () -> Void
    private var recoveryDraftID = UUID()
    private var recoveryNoteID = UUID()
    private var recoveryLibraryPath: String?
    private var recoveryBaseline = ""
    private var suppressCheckpoint = false
    private let deleteSavedNote: @MainActor (MeetingNote) -> Bool
    private let countWords: @Sendable (String) async -> Int
    private let suggestTask: @Sendable (String) async -> QuickCaptureTaskParser.Suggestion?
    private let discardConfirmation: (@MainActor () -> Bool)?
    private var analysisRevision = UUID()
    private var analysisRequests: AsyncStream<QuickNoteAnalysisRequest>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private let runAssistant: @Sendable (
        NoteAction,
        String,
        NoteAssistantEngine
    ) async throws -> String
    private let loadAvailableEngines: @Sendable () async -> [NoteAssistantEngine]
    private var engineRefreshID = UUID()
    private var panel: NSPanel?
    private let windowDelegate = QuickNoteWindowDelegate()
    /// The exact saved version this pad is editing, including its file revision.
    ///
    /// Keeping only the ID and path allowed a reload after an external edit
    /// to supply a newer revision to the next autosave, silently overwriting
    /// that edit. The pad must keep its own base until its words are saved.
    /// The stable path also prevents a changing generated title from creating
    /// a second file after each hands-free chunk.
    private var savedNote: MeetingNote?
    private var startedAt = Date()
    private var saveDebounce: Task<Void, Never>?
    private var assistantTask: Task<Void, Never>?
    private var assistantRunID: UUID?
    /// Identifies the currently presented pad. A result from a previous
    /// presentation must never be allowed to land in a newly opened note,
    /// even if the words happen to be identical.
    private var presentationID = UUID()
    /// Changes on every user edit. An assistant result is only valid for the
    /// exact revision whose words were sent to it.
    private(set) var textRevision = 0
    /// Ends any dictation session aimed at this pad before the window goes
    /// away. A recognizer can deliver its final words after a close request;
    /// without invalidating that session, the no-field route presents the pad
    /// again and makes a discarded note appear to come back.
    var onDismissRequested: (@MainActor () -> Void)?

    init(
        store: MarkdownStore,
        recovery: DraftJournal? = nil,
        deleteSavedNote: (@MainActor (MeetingNote) -> Bool)? = nil,
        assistantRun: (@Sendable (
            NoteAction,
            String,
            NoteAssistantEngine
        ) async throws -> String)? = nil,
        availableEngines: (@Sendable () async -> [NoteAssistantEngine])? = nil,
        countWords: (@Sendable (String) async -> Int)? = nil,
        discardConfirmation: (@MainActor () -> Bool)? = nil,
        suggestTask: (@Sendable (String) async -> QuickCaptureTaskParser.Suggestion?)? = nil,
        defaults: UserDefaults = .standard,
        openFilingLibrary: (@MainActor () -> Void)? = nil,
        announceVoiceStatus: (@MainActor (String) -> Void)? = nil
    ) {
        self.store = store
        self.announceVoiceStatus = announceVoiceStatus
        self.defaults = defaults
        self.recovery = recovery
        self.openFilingLibrary = openFilingLibrary ?? { AppModel.shared.openLibrary() }
        self.deleteSavedNote = deleteSavedNote ?? { store.delete($0) }
        self.countWords = countWords ?? { Self.countWords(in: $0) }
        self.suggestTask = suggestTask ?? { QuickCaptureTaskParser.suggestion(in: $0) }
        self.discardConfirmation = discardConfirmation
        let assistant = NoteAssistant()
        self.runAssistant = assistantRun ?? { action, text, engine in
            try await assistant.run(action, on: text, using: engine)
        }
        self.loadAvailableEngines = availableEngines ?? {
            await assistant.availableEngines()
        }
        self.engine = Self.restoredEngine(defaults: defaults)
        self.isContinuous = defaults.bool(
            forKey: Keys.continuous
        )
        recoveryObservation = recovery?.$statusMessage.sink { [weak self] message in
            self?.recoveryWarning = message
        }
        // A popover can stay open while Finder copies enter the library. Its
        // choices must refresh even when nobody types another word in the pad.
        libraryObservation = store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    deinit {
        analysisRequests?.finish()
        analysisTask?.cancel()
    }

    // MARK: - Background text analysis

    /// Reopening the pad can change the meaning of "tomorrow" even when its
    /// text is unchanged. Reuse a current count, but refresh the dated offer.
    func refreshTaskSuggestion() {
        scheduleTextAnalysis(keepingCount: true)
    }

    func applyTaskSuggestion(_ suggestion: QuickCaptureTaskParser.Suggestion) {
        guard let current = taskSuggestion,
              current.dueDate == suggestion.dueDate,
              current.cueLabel == suggestion.cueLabel,
              current.paragraph.utf8.elementsEqual(suggestion.paragraph.utf8)
        else { return }
        text = QuickCaptureTaskParser.applying(current, to: text)
    }

    private func scheduleTextAnalysis(keepingCount: Bool = false) {
        analysisRevision = UUID()
        let nextCount: Int? = text.isEmpty ? 0 : (keepingCount ? wordCount : nil)
        if wordCount != nextCount { wordCount = nextCount }
        if taskSuggestion != nil { taskSuggestion = nil }
        // One consumer and one replaceable pending buffer bound the work when
        // typing outruns counting. A task per edit would retain every large
        // intermediate note and gives no ordering guarantee.
        if analysisRequests == nil, !text.isEmpty {
            let pair = AsyncStream<QuickNoteAnalysisRequest>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
            analysisRequests = pair.continuation
            let countWords = countWords
            let suggestTask = suggestTask
            let worker: @Sendable () async -> Void = { [weak self] in
                for await request in pair.stream {
                    guard !Task.isCancelled else { return }
                    let count: Int
                    if let knownCount = request.knownCount {
                        count = knownCount
                    } else {
                        count = await countWords(request.text)
                    }
                    guard !Task.isCancelled else { return }
                    // Skip parsing a superseded snapshot. Publish its count
                    // first so suggestion work cannot hold statistics hostage.
                    guard await self?.acceptWordCount(count, revision: request.revision) == true
                    else { continue }
                    let suggestion = request.text.isEmpty ? nil : await suggestTask(request.text)
                    guard !Task.isCancelled else { return }
                    await self?.acceptTaskSuggestion(suggestion, revision: request.revision)
                }
            }
            analysisTask = Task.detached(priority: .utility, operation: worker)
        }
        // An empty request also replaces any queued old text. Its result cannot
        // overwrite a newer edit because clearing advances the revision too.
        analysisRequests?.yield(QuickNoteAnalysisRequest(
            text: text, revision: analysisRevision, knownCount: nextCount
        ))
    }

    private func acceptWordCount(_ count: Int, revision: UUID) -> Bool {
        guard revision == analysisRevision else { return false }
        if wordCount != count { wordCount = count }
        return true
    }

    private func acceptTaskSuggestion(
        _ suggestion: QuickCaptureTaskParser.Suggestion?, revision: UUID
    ) {
        guard revision == analysisRevision else { return }
        guard taskSuggestion != nil || suggestion != nil else { return }
        taskSuggestion = suggestion
    }

    /// Match String.split's Character whitespace behavior without allocating
    /// one substring per word. Scalar or byte separators would change counts
    /// for grapheme clusters containing whitespace and combining characters.
    nonisolated static func countWords(in text: String) -> Int {
        var count = 0
        var insideWord = false
        var charactersSinceCancellationCheck = 0
        for character in text {
            if character.isWhitespace {
                insideWord = false
            } else if !insideWord {
                count += 1
                insideWord = true
            }
            charactersSinceCancellationCheck += 1
            if charactersSinceCancellationCheck == 1_024 {
                if Task.isCancelled { return 0 }
                charactersSinceCancellationCheck = 0
            }
        }
        return count
    }

    /// The engine to start with, which is not simply the remembered one.
    ///
    /// Consent is the authority, and it is checked here rather than trusted to
    /// have been checked when the choice was made. A stored preference can
    /// outlive the agreement that justified it: written by an earlier version
    /// that had no consent step, restored from a backup, or left behind when
    /// the agreement was withdrawn. Any of those would otherwise mean notes
    /// leaving the Mac on launch with nobody having said yes.
    static func restoredEngine(defaults: UserDefaults = .standard) -> NoteAssistantEngine {
        let restored = defaults.string(forKey: Keys.engine)
            .flatMap(NoteAssistantEngine.init(rawValue:)) ?? .onDevice
        guard restored.leavesTheMac else { return restored }
        guard defaults.bool(forKey: Keys.consent(restored)) else {
            // Repair the stored value too, so it cannot resurface later.
            defaults.set(
                NoteAssistantEngine.onDevice.rawValue,
                forKey: Keys.engine
            )
            return .onDevice
        }
        return restored
    }

    // MARK: - Capture

    func present() {
        // A pending failure means the text on screen is the only copy, so a
        // new capture must not begin by clearing it.
        if !isPresenting, !hasUnsavedFailure {
            beginPresentation()
            suppressCheckpoint = true
            text = ""
            savedNote = nil
            recoveryBaseline = ""
            message = nil
            filingCompletionMessage = nil
            hasUnsavedEdits = false
            startedAt = Date()
            recoveryDraftID = UUID()
            recoveryNoteID = UUID()
            recoveryLibraryPath = Self.libraryPath(store.storageURL)
            suppressCheckpoint = false
            // Hands-free is a session, not a preference. The stored value
            // outlives the session that set it, so restoring it would show a
            // ticked box with nothing listening. Nook also must not open the
            // microphone because a pad appeared: the tick follows a session
            // the user starts here, and starts off every time.
            isContinuous = false
        }
        if !isPresenting {
            isPresenting = true
            showWindow()
            refreshEngines()
        }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Raising a panel does not make its editor first responder. Issue the
        // one-shot request after the hosting view is attached, including when
        // an already-open pad is explicitly brought forward again.
        editorFocusToken &+= 1
    }

    /// Appends a finalized chunk while the user is still speaking.
    func append(_ chunk: String) {
        if chunk == "\n" || chunk == "\n\n" {
            text += chunk
            return
        }
        let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if text.isEmpty {
            text = trimmed
        } else if text.hasSuffix("\n") {
            text += trimmed
        } else {
            text += " " + trimmed
        }
    }

    /// Literal speech enters the normal autosave path before a correction is
    /// offered. Dismissing a proposal therefore cannot throw away what was heard.
    @discardableResult
    func receiveDictation(_ originalWords: String, inserting spoken: String, allowsCorrections: Bool = true) -> Bool {
        let intent = allowsCorrections ? VoiceCorrectionIntent.parse(originalWords) : nil
        let previous = lastDictatedEdit
        let before = text
        append(intent == nil ? spoken : originalWords)
        guard !text.utf8.elementsEqual(before.utf8) else { return intent != nil }
        lastDictatedEdit = DictatedEdit(before: before, after: text)
        voicePresentationID = presentationID
        voiceLibraryGeneration = store.storageGeneration
        if let intent {
            voiceCorrection = VoiceCorrectionProposal.make(
                intent: intent, utterance: originalWords, before: before,
                literalText: text, previous: previous
            )
            reportVoiceStatus(voiceCorrection == nil
                ? "Words kept. There is no unchanged dictated phrase or unambiguous previous list item to correct."
                : "Correction proposed. Your words are kept until you review and apply it.")
        } else if spoken == "\n" || spoken == "\n\n" {
            voiceUndo = DictatedEdit(before: before, after: text)
            reportVoiceStatus(spoken == "\n" ? "New line inserted. Undo is available." : "New paragraph inserted. Undo is available.")
        } else {
            // Announce insertion without filling the small pad with a standing
            // success banner for every settled phrase.
            announceVoice("Dictated words inserted.")
        }
        return intent != nil
    }

    func isCurrentVoiceCorrection(_ proposal: VoiceCorrectionProposal) -> Bool {
        voiceCorrection?.id == proposal.id && voicePresentationID == presentationID
            && voiceLibraryGeneration == store.storageGeneration
            && text.utf8.elementsEqual(proposal.expectedText.utf8)
    }

    func beginVoiceCorrectionReview(_ proposal: VoiceCorrectionProposal) -> Bool {
        guard filingRequest == nil, !isReviewingVoiceCorrection,
              isCurrentVoiceCorrection(proposal) else { return false }
        // Review is an explicit pause. A recognizer's late callback cannot
        // change the text underneath a pending destructive decision.
        isContinuous = false
        onDismissRequested?()
        isReviewingVoiceCorrection = true
        return true
    }

    func endVoiceCorrectionReview() {
        isReviewingVoiceCorrection = false
        editorFocusToken &+= 1
    }

    func keepVoiceWords(_ proposal: VoiceCorrectionProposal) {
        guard voiceCorrection?.id == proposal.id else { return }
        voiceCorrection = nil
        reportVoiceStatus("Correction cancelled. Your dictated words were kept.")
    }

    @discardableResult
    func applyVoiceCorrection(_ proposal: VoiceCorrectionProposal, replacement: String) -> Bool {
        guard isCurrentVoiceCorrection(proposal),
              let corrected = proposal.correctedText(replacement: replacement) else {
            reportVoiceStatus("The note changed or replacement words are missing. Your current words were kept.")
            return false
        }
        let before = text
        guard replaceVoiceText(expected: before, with: corrected, actionName: "Voice Correction") else { return false }
        voiceUndo = DictatedEdit(before: before, after: corrected)
        voicePresentationID = presentationID
        voiceLibraryGeneration = store.storageGeneration
        reportVoiceStatus("Voice correction applied. Undo is available.")
        return true
    }

    var canUndoVoiceCorrection: Bool {
        guard let voiceUndo else { return false }
        return voicePresentationID == presentationID && voiceLibraryGeneration == store.storageGeneration
            && text.utf8.elementsEqual(voiceUndo.after.utf8)
    }

    func undoVoiceCorrection() {
        guard canUndoVoiceCorrection, let edit = voiceUndo else { return }
        guard replaceVoiceText(expected: edit.after, with: edit.before, actionName: "Restore Dictated Words") else { return }
        reportVoiceStatus("Voice correction undone. Your original words were restored.")
    }

    private func replaceVoiceText(expected: String, with replacement: String, actionName: String) -> Bool {
        switch editorPort.replaceText(expected: expected, with: replacement, actionName: actionName) {
        case .refused:
            reportVoiceStatus("Finish editing or composing text before applying this correction. Your words were kept.")
            return false
        case .applied, .unavailable:
            text = replacement
            return true
        }
    }

    private func reportVoiceStatus(_ status: String) {
        voiceStatus = status
        announceVoice(status)
    }

    private func announceVoice(_ status: String) {
        if let announceVoiceStatus { announceVoiceStatus(status) }
        else { editorPort.announce(status) }
    }

    /// Swaps the words just dictated for their rewritten form.
    ///
    /// Matched by content rather than position, so anything the user typed
    /// themselves in the meantime is left exactly where it is.
    func replaceLastDictation(with rewritten: String, spoken: String, expectedRevision: Int? = nil) {
        guard expectedRevision == nil || expectedRevision == textRevision else { return }
        let spoken = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty, let range = text.range(
            of: spoken,
            options: [.backwards]
        ) else {
            return
        }
        text.replaceSubrange(range, with: rewritten)
    }

    func close() {
        // Speaking into a window and having it vanish unsaved would be the
        // worst possible behaviour for something whose whole purpose is to
        // catch a thought. That includes the case where the save was tried
        // and refused: the pad stays put with the reason on it rather than
        // taking the only copy of the words with it.
        guard canClose() else {
            panel?.makeKeyAndOrderFront(nil)
            return
        }
        filingRequest = nil
        prepareToDismiss()
        hasUnsavedEdits = false
        filingCompletionMessage = nil
        isPresenting = false
        panel?.orderOut(nil)
        panel = nil
    }

    /// Writes whatever is pending and says whether the window may go.
    ///
    /// Also the window delegate's answer to a click on the close button, which
    /// is the one route that would otherwise take the panel away before
    /// anything had a chance to object.
    func canClose() -> Bool {
        saveDebounce?.cancel()
        saveDebounce = nil
        saveIfNeeded()
        return !hasUnsavedFailure
    }

    /// Saves the pad's words as the app is quitting.
    ///
    /// Returns the reason it could not, or nil when nothing is at risk. The
    /// pad saves shortly after typing stops, so a quit lands inside that
    /// window routinely and the newest sentence is normally the one still
    /// only in memory.
    func saveForTermination() -> String? {
        saveDebounce?.cancel()
        saveDebounce = nil
        saveIfNeeded()
        guard hasUnsavedFailure else { return nil }
        return message ?? "Nook couldn’t save the quick note."
    }

    /// Saves shortly after typing stops, so "Saved" is a fact rather than a
    /// promise the user has to trigger.
    ///
    /// Debounced rather than saved per keystroke: the store rewrites the whole
    /// Markdown file, and the pad is often being dictated into a word at a
    /// time.
    func scheduleSave() {
        hasUnsavedEdits = true
        saveDebounce?.cancel()
        saveDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            self.saveIfNeeded()
        }
    }

    /// Saves and closes, from the pad's own button or its keyboard shortcut.
    func done() {
        requestFiling()
    }

    /// A close/save request makes filing deliberate without changing autosave.
    /// Stop live work before presenting choices; Cancel never restarts capture.
    func requestFiling() {
        guard filingRequest == nil, !isReviewingVoiceCorrection else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            close()
            return
        }
        prepareToDismiss()
        filingRequest = QuickNoteFilingRequest(
            libraryPath: store.storageURL.path,
            choices: filingChoices,
            hasOmittedDuplicates: hasOmittedDuplicateNotes
        )
    }

    /// Throws the note away, asking first when there is enough of it to miss.
    ///
    /// A debounced save may already have written the file, so discarding has
    /// to delete what was written rather than merely closing the window.
    func discardWithConfirmation() {
        guard canDiscard else { return }
        // A pending count cannot authorize destruction using an older, shorter
        // revision's total. Confirm conservatively until this revision is known.
        // Zero visible words also cannot describe a saved note that Undo hid:
        // removing that file is always an explicit, confirmed decision.
        let mayDiscardWithoutConfirmation = wordCount.map {
            $0 <= Self.discardConfirmationWordCount && ($0 > 0 || savedNote == nil)
        } == true
        guard mayDiscardWithoutConfirmation
            || (discardConfirmation?() ?? confirmDiscard())
        else { return }
        discard()
    }

    func discard() {
        filingRequest = nil
        if let saved = savedNote {
            guard recoveryLibraryPath == nil
                    || recoveryLibraryPath == Self.libraryPath(store.storageURL),
                  let file = saved.fileURL,
                  Self.libraryPath(file.deletingLastPathComponent())
                    == Self.libraryPath(store.storageURL),
                  let revision = saved.fileRevision,
                  let current = try? Data(contentsOf: file),
                  MeetingNote.contentRevision(current) == revision else {
                message = "The original note changed or is in another folder. Your draft and the saved file were kept."
                hasUnsavedFailure = true
                return
            }
        }
        saveDebounce?.cancel()
        saveDebounce = nil
        prepareToDismiss()
        if let saved = savedNote {
            guard deleteSavedNote(saved) else {
                message = store.lastError
                    ?? "Nook couldn’t move this note to the Trash."
                hasUnsavedFailure = true
                panel?.makeKeyAndOrderFront(nil)
                return
            }
        }
        recovery?.resolve(recoveryDraftID)
        suppressCheckpoint = true
        savedNote = nil
        recoveryBaseline = ""
        text = ""
        suppressCheckpoint = false
        lastSavedAt = nil
        hasUnsavedEdits = false
        hasUnsavedFailure = false
        message = nil
        filingCompletionMessage = nil
        isPresenting = false
        panel?.orderOut(nil)
        panel = nil
    }

    private func confirmDiscard() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard this note?"
        alert.informativeText =
            savedNote != nil && wordCount == 0
                ? "This pad is empty. Discard moves the saved note it belongs to into the Trash."
                : "These words are not kept anywhere else, and this cannot be undone."
        alert.addButton(withTitle: "Keep It")
        alert.addButton(withTitle: "Discard")
        // The safe option is the default, so a reflexive Return keeps the
        // note rather than destroying it.
        alert.buttons.first?.keyEquivalent = "\r"
        alert.buttons.last?.keyEquivalent = ""
        panel?.makeKeyAndOrderFront(nil)
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Short enough to be a stray thought rather than work worth confirming.
    private static let discardConfirmationWordCount = 12

    // MARK: - Saving

    @discardableResult
    func saveIfNeeded() -> MeetingNote? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            // An empty replacement still belongs to the saved pad. Closing
            // must not silently restore the old words or erase its checkpoint.
            if let savedNote, text != savedNote.summary {
                hasUnsavedFailure = true
                hasUnsavedEdits = true
                message = "The note is empty. Add text or choose Discard to remove it."
                isShowingEmptyDraftValidation = true
                return nil
            }
            recovery?.resolve(recoveryDraftID)
            recoveryDraftID = UUID()
            hasUnsavedFailure = false
            hasUnsavedEdits = false
            return nil
        }

        guard recoveryLibraryPath == nil
                || recoveryLibraryPath == Self.libraryPath(store.storageURL) else {
            hasUnsavedFailure = true
            hasUnsavedEdits = true
            message = "This draft belongs to another notes folder. Switch back to save it."
            return nil
        }
        if let savedNote, let file = savedNote.fileURL,
           !FileManager.default.fileExists(atPath: file.path) {
            hasUnsavedFailure = true
            hasUnsavedEdits = true
            message = "The original note is no longer available. Your draft has not been saved over another file."
            return nil
        }

        var note = savedNote ?? MeetingNote(
            id: recoveryNoteID,
            kind: .spoken,
            title: NoteTitleGenerator.title(for: body),
            startedAt: startedAt,
            endedAt: Date(),
            sourceApp: "Spoken note",
            summary: body
        )
        note.title = NoteTitleGenerator.title(for: body)
        note.endedAt = Date()
        note.summary = body
        do {
            if note.fileURL == nil {
                note.fileURL = store.destinationForNewNote(note)
            }
            let markdown = MarkdownCodec.encode(note)
            let encoded = Data(markdown.utf8)
            if let recovery, var record = checkpointRecord(),
               let destination = note.fileURL {
                record.completion = DraftCompletion(
                    targetPath: destination.path,
                    noteID: note.id,
                    revision: MeetingNote.contentRevision(encoded)
                )
                // An unavailable recovery directory must not disable ordinary
                // saving. Its failure stays visible through the journal; the
                // successful note write still gets a chance to protect words.
                try? recovery.persistSynchronously(record)
            }
            let saved = try store.save(note)
            guard let destination = saved.fileURL,
                  try Data(contentsOf: destination) == encoded else {
                throw MarkdownStoreError.writeVerificationFailed
            }
            savedNote = saved
            recoveryBaseline = markdown
            recovery?.resolve(recoveryDraftID)
            recoveryDraftID = UUID()
            lastSavedAt = Date()
            message = nil
            hasUnsavedFailure = false
            hasUnsavedEdits = false
            return saved
        } catch {
            message = "Couldn’t save this note: \(error.localizedDescription)"
            hasUnsavedFailure = true
            hasUnsavedEdits = true
            return nil
        }
    }

    func saveAndOpenInLibrary() {
        guard let note = saveIfNeeded() else { return }
        prepareToDismiss()
        filingCompletionMessage = nil
        isPresenting = false
        panel?.orderOut(nil)
        panel = nil
        AppModel.shared.openLibrary(noteID: note.id)
    }

    /// Filing is a move, not a copy: autosave may already have written a
    /// separate spoken note. Commit and verify the destination before moving
    /// that source to Trash. A partial cleanup leaves a visible retained copy.
    ///
    /// Meeting/digest text belongs in My notes; a spoken note's entire source
    /// ends in its body, so appending exact source preserves unknown metadata.
    @discardableResult
    func fileIntoNote(_ target: MeetingNote) -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return false }
        // A button may outlive a reload or a folder change. Refuse before
        // saving the pad or resolving its checkpoint, and retain the selected
        // target's original revision for the store's external-edit checks.
        guard recoveryLibraryPath == nil
                || recoveryLibraryPath == Self.libraryPath(store.storageURL) else {
            message = "This draft belongs to another notes folder. Switch back before filing it. Your words are still here."
            return false
        }
        guard !store.isLoading else {
            message = "The library is refreshing. Wait for it to finish, then choose the note again. Your words are still here."
            return false
        }
        guard !store.duplicateNoteIDs.contains(target.id) else {
            message = "That note now shares its note ID with another file. Review the copies in Library before filing. Your words are still here."
            return false
        }
        guard target.id != recoveryNoteID,
              target.libraryIdentity != savedNote?.libraryIdentity,
              let file = target.fileURL, file.isFileURL,
              Self.libraryPath(file.deletingLastPathComponent()) == Self.libraryPath(store.storageURL),
              let current = store.note(matching: target.libraryIdentity),
              current.kind == target.kind else {
            message = "That note is no longer available in this notes folder. Choose a note again. Your words are still here."
            return false
        }
        guard let revision = target.fileRevision, current.fileRevision == revision else {
            message = "That note changed after it was offered. Choose it again to review the current file before filing. Your words are still here."
            return false
        }
        // Cancelled before the write, not after: a debounce that fired in
        // between would put the standalone note straight back.
        saveDebounce?.cancel()
        saveDebounce = nil
        // A move must not trash newer content in the source file while filing
        // an older pad draft. First save through the pad's original revision;
        // a conflict leaves both files and the draft intact.
        if savedNote != nil, saveIfNeeded() == nil { return false }
        do {
            if target.kind == .spoken {
                let snapshot = try store.markdownSnapshot(for: target)
                guard snapshot.revision == revision else {
                    message = "That note changed after it was offered. Choose it again. Your words are still here."
                    return false
                }
                let separator = snapshot.markdown.hasSuffix("\n\n") ? ""
                    : (snapshot.markdown.hasSuffix("\n") ? "\n" : "\n\n")
                let appended = snapshot.markdown + separator + body
                try store.saveRawMarkdown(appended, for: target, expectedRevision: revision)
                guard try store.rawMarkdown(for: target).utf8.elementsEqual(appended.utf8) else {
                    throw MarkdownStoreError.writeVerificationFailed
                }
            } else {
                let existing = target.personalNotes
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let joined = existing.isEmpty ? body : "\(existing)\n\n\(body)"
                _ = try store.updatePersonalNotes(joined, for: target)
            }
            // The words are in the destination now, so the autosaved copy goes to
            // the Trash exactly as discarding it would send it there.
            var hasStrandedCopy = false
            if let autosaved = savedNote {
                let directory = store.storageURL
                let generation = store.storageGeneration
                hasStrandedCopy = !store.delete(autosaved) {
                    try store.validateMergeSource(
                        autosaved, directory: directory, generation: generation
                    )
                }
            }
            filingRequest = nil
            recovery?.resolve(recoveryDraftID)
            // The completed filing must not be replayed, and a new thought
            // must never reuse the old copy's UUID or resolved checkpoint.
            // End the old assistant/capture session even when this window stays.
            prepareToDismiss()
            suppressCheckpoint = true
            text = ""
            savedNote = nil
            recoveryBaseline = ""
            recoveryDraftID = UUID()
            recoveryNoteID = UUID()
            recoveryLibraryPath = Self.libraryPath(store.storageURL)
            startedAt = Date()
            suppressCheckpoint = false
            lastSavedAt = nil
            hasUnsavedEdits = false
            hasUnsavedFailure = false
            message = nil
            if hasStrandedCopy {
                filingCompletionMessage = "Filed successfully, but Nook couldn’t move the earlier saved copy to Trash."
                // Done/Close remain available, but a partial success must not
                // dismiss its own explanation before the user can read it.
                panel?.makeKeyAndOrderFront(nil)
                return true
            }
            filingCompletionMessage = nil
            isPresenting = false
            panel?.orderOut(nil)
            panel = nil
            return true
        } catch {
            message = "Couldn’t file into that note: \(error.localizedDescription)"
            return false
        }
    }

    /// Every unambiguous destination in this library, newest first. The pad's
    /// own autosaved note is not an append target and can never trash itself.
    var availableFilingTargets: [MeetingNote] {
        let directory = store.storageURL.standardizedFileURL
        return store.notes.filter {
            $0.id != recoveryNoteID && $0.libraryIdentity != savedNote?.libraryIdentity
                && !store.duplicateNoteIDs.contains($0.id)
                && $0.fileURL?.isFileURL == true
                && $0.fileURL?.deletingLastPathComponent().standardizedFileURL == directory
        }.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return ($0.libraryIdentity.filePath ?? "") < ($1.libraryIdentity.filePath ?? "")
        }
    }

    var hasOmittedDuplicateNotes: Bool {
        store.notes.contains { store.duplicateNoteIDs.contains($0.id) }
    }

    var filingChoices: [QuickNoteFilingChoice] {
        QuickNoteFilingChoice.choices(for: availableFilingTargets)
    }

    /// Reviewing a shared ID must remain possible even if saving this pad is
    /// blocked. This route neither files its words nor closes its editor.
    func reviewFilingTargetsInLibrary() {
        openFilingLibrary()
    }

    func dismissFilingCompletion() {
        filingCompletionMessage = nil
    }

    /// Starts a checklist line at the cursor from the toolbar or keyboard.
    func insertChecklistLine() {
        editorPort.insertLineStarting(with: "- [ ] ")
    }

    // MARK: - Assistance

    @discardableResult
    func refreshEngines() -> Task<Void, Never> {
        let refreshID = UUID()
        engineRefreshID = refreshID
        return Task { @MainActor [weak self] in
            guard let self else { return }
            let engines = await self.loadAvailableEngines()
            guard !Task.isCancelled, self.engineRefreshID == refreshID else { return }
            self.availableEngines = engines
            // A previously chosen engine can disappear when a tool is removed.
            // Prior consent permits another explicit choice, not an automatic
            // reversal of Keep on this Mac when its local model is unavailable.
            if !engines.contains(self.engine) {
                self.setSelectedEngine(.onDevice)
            }
        }
    }

    @discardableResult
    func run(_ action: NoteAction) -> Task<Void, Never>? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !isWorking, !isPreparingForTermination else { return nil }
        guard isSelectedAssistantAvailable, hasConsented(to: engine) else {
            message = "Choose an available assistant before running a note action. Your words can still be edited and saved."
            return nil
        }

        isWorking = true
        runningAction = action
        runningEngine = engine
        isStoppingAssistant = false
        message = nil
        let engine = self.engine
        let presentationID = self.presentationID
        let textRevision = self.textRevision
        let runID = UUID()
        assistantRunID = runID
        assistantTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                // An older provider may ignore cancellation and finish after
                // a new presentation has started another action. Only that
                // action may clear the current spinner and task reference.
                if self.assistantRunID == runID {
                    self.isWorking = false
                    self.runningAction = nil
                    self.runningEngine = nil
                    self.isStoppingAssistant = false
                    self.assistantTask = nil
                    self.assistantRunID = nil
                }
            }
            guard !Task.isCancelled, !self.isStoppingAssistant else { return }
            do {
                let result = try await self.runAssistant(
                    action,
                    body,
                    engine
                )
                // A model or CLI can finish after the person edited, closed,
                // discarded, or reopened the pad. Its output belongs only to
                // the exact presentation and revision it saw.
                guard !Task.isCancelled,
                      !self.isStoppingAssistant,
                      self.assistantRunID == runID,
                      self.isPresenting,
                      self.presentationID == presentationID,
                      self.textRevision == textRevision,
                      self.text.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      ) == body
                else { return }
                self.apply(result, for: action)
            } catch {
                guard !Task.isCancelled,
                      !self.isStoppingAssistant,
                      self.assistantRunID == runID,
                      self.isPresenting,
                      self.presentationID == presentationID,
                      self.textRevision == textRevision,
                      self.text.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      ) == body
                else { return }
                self.message = error.localizedDescription
            }
        }
        assistantTask = task
        return task
    }

    private func requestAssistantStop() {
        guard isWorking else { return }
        // Reject results immediately, but do not describe cancellation as
        // finished until the assistant returns. A CLI may still be cleaning up.
        isStoppingAssistant = true
        assistantTask?.cancel()
    }

    /// Quit must wait for the actual assistant operation, not just a canceled
    /// Task handle. A timeout keeps Nook open with its stopping disclosure.
    func prepareAssistantForTermination(timeout: Double = 5) async -> Bool {
        isPreparingForTermination = true
        requestAssistantStop()
        guard let task = assistantTask else { return true }
        let finished = await withDeadline(seconds: timeout) {
            await task.value
            return true
        }
        return finished == true
    }

    func cancelApplicationTermination() {
        isPreparingForTermination = false
    }

    private func apply(_ result: String, for action: NoteAction) {
        if action.replacesNote {
            // A rewrite is proposed, not trusted. A spoken note routinely
            // reads as a request, and tidy or expand hands it to a model that
            // will happily answer it instead. When the result stops being
            // recognisably the same note, the spoken words stay and the
            // rewrite is dropped.
            switch DictationOutputGuard.evaluate(
                refined: result,
                spoken: text,
                maximumLengthRatio: action.maximumRewriteGrowth
            ) {
            case .accept(let rewritten):
                text = rewritten
                saveIfNeeded()
            case .reject:
                message = Self.keptYourOwnWordsNotice
            }
        } else {
            // Appending is not a safe operation just because it keeps the
            // spoken words. Whatever comes back is written into the user's
            // document under a heading, and a note that reads as a question
            // gets answered rather than worked on. The result is checked
            // against the note first, exactly as a rewrite is.
            switch NoteActionOutputGuard.evaluate(
                result,
                for: action,
                note: text
            ) {
            case .accept(let checked):
                // Appended under a heading so the note keeps the spoken words
                // and the derived material side by side, rather than one
                // replacing the other silently.
                text += "\n\n## \(action.title)\n\n\(checked)"
                saveIfNeeded()
            case .reject:
                message = Self.keptYourOwnWordsNotice
            }
        }
    }

    #if DEBUG
    /// Runs a model result through the same path a real one takes.
    ///
    /// No engine is available in a test run, so without this the guard around
    /// appended output could only be tested in isolation from the note it is
    /// supposed to protect.
    func applyForTesting(_ result: String, for action: NoteAction) {
        apply(result, for: action)
    }
    #endif

    // MARK: - Window

    private func showWindow() {
        guard panel == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Quick note"
        // Small enough to sit beside whatever the user is working in, large
        // enough that the bar's controls never collapse into each other.
        panel.contentMinSize = NSSize(width: 380, height: 240)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(
            // Every @EnvironmentObject the pad's view reads must be injected
            // here explicitly: this panel is built by hand rather than through
            // a declared scene, so AppModel's scene-wide injections never
            // reach it. The dictation coordinator was added for the live
            // partial line and hands-free mode, and omitting it here crashed
            // the app the first time a no-field dictation opened the pad.
            rootView: QuickNoteView()
                .environmentObject(self)
                .environmentObject(AppModel.shared.dictation)
                .environmentObject(ShortcutStore.shared)
        )
        // Where the pad was left is where the next thought should land. The
        // window is rebuilt on every present, so without an autosaved frame it
        // would walk back to the middle of the screen each time and cover
        // whatever the user was reading.
        panel.setFrameAutosaveName(Self.frameAutosaveName)
        if !panel.setFrameUsingName(Self.frameAutosaveName) {
            panel.center()
        }
        // `NSWindow.delegate` is weak, so the delegate is owned here.
        windowDelegate.onClose = { [weak self] in
            self?.close()
        }
        windowDelegate.onShouldClose = { [weak self] in
            guard let self else { return true }
            self.requestFiling()
            return false
        }
        // The controller can be instantiated without the full app in tests,
        // so the production dictation dependency is attached only when a real
        // window is created. Tests may install their own closure first.
        if onDismissRequested == nil {
            onDismissRequested = {
                AppModel.shared.dictation.cancel()
            }
        }
        panel.delegate = windowDelegate
        self.panel = panel
    }

    /// Makes every exit from the pad terminate the same capture session.
    /// Turning hands-free off first also prevents a final delivery from
    /// scheduling another listening window while cancellation is settling.
    private func prepareToDismiss() {
        // The assistant may still be waiting on Foundation Models or a CLI.
        // Cancellation is only an optimisation: the identity and revision
        // checks in its completion are the actual safety boundary because a
        // provider is allowed to ignore cancellation.
        requestAssistantStop()
        presentationID = UUID()
        voiceCorrection = nil
        voiceUndo = nil
        lastDictatedEdit = nil
        voiceStatus = nil
        textRevision &+= 1
        isContinuous = false
        onDismissRequested?()
    }

    private func beginPresentation() {
        presentationID = UUID()
        voiceCorrection = nil
        voiceUndo = nil
        lastDictatedEdit = nil
        voiceStatus = nil
        textRevision &+= 1
    }

    // MARK: - Recovery checkpoints

    private static func libraryPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func checkpointEdit() {
        guard !suppressCheckpoint, recovery != nil else { return }
        if recoveryLibraryPath == nil {
            recoveryLibraryPath = Self.libraryPath(store.storageURL)
        }
        guard !text.utf8.elementsEqual((savedNote?.summary ?? "").utf8) else {
            recovery?.resolve(recoveryDraftID)
            recoveryDraftID = UUID()
            return
        }
        if let record = checkpointRecord() { recovery?.checkpoint(record) }
    }

    private func checkpointRecord() -> DraftCheckpoint? {
        guard let recovery else { return nil }
        return DraftCheckpoint(
            id: recoveryDraftID,
            kind: .quickNote,
            libraryPath: recoveryLibraryPath ?? Self.libraryPath(store.storageURL),
            originalFilePath: savedNote?.fileURL.map(Self.libraryPath),
            noteID: savedNote?.id,
            title: savedNote?.title ?? "Unfinished quick note",
            text: text,
            baseline: recoveryBaseline,
            baselineRevision: savedNote?.fileRevision,
            createdAt: startedAt,
            sessionID: recovery.sessionID
        )
    }

    func libraryWillChange() {
        voiceCorrection = nil
        voiceUndo = nil
        lastDictatedEdit = nil
        voiceStatus = nil
        if !text.isEmpty || savedNote != nil {
            if recoveryLibraryPath == nil {
                recoveryLibraryPath = Self.libraryPath(store.storageURL)
            }
            checkpointEdit()
        }
        saveDebounce?.cancel()
        saveDebounce = nil
        recovery?.flushSynchronously()
    }

    /// Called only after an explicit deletion succeeded. It cannot allow a
    /// later autosave or assistant completion to recreate that deleted note.
    func noteWasDeleted(_ note: MeetingNote) {
        guard savedNote?.id == note.id,
              savedNote?.fileURL?.standardizedFileURL
                == note.fileURL?.standardizedFileURL else { return }
        saveDebounce?.cancel()
        saveDebounce = nil
        prepareToDismiss()
        recovery?.resolve(recoveryDraftID)
        suppressCheckpoint = true
        savedNote = nil
        recoveryBaseline = ""
        text = ""
        suppressCheckpoint = false
        hasUnsavedFailure = false
        hasUnsavedEdits = false
        filingCompletionMessage = nil
        isPresenting = false
        panel?.orderOut(nil)
        panel = nil
    }

    private static let frameAutosaveName = "QuickNote"

    private enum Keys {
        static let engine = "quickNoteEngine"
        static let continuous = "quickNoteContinuous"

        static func consent(_ engine: NoteAssistantEngine) -> String {
            // Earlier Codex consent promised access only to the current note.
            // That approval does not cover the clarified file-read warning.
            engine == .codex
                ? "quickNoteConsent.codex.v2"
                : "quickNoteConsent.\(engine.rawValue)"
        }
    }
}

private struct QuickNoteAnalysisRequest: Sendable {
    let text: String
    let revision: UUID
    let knownCount: Int?
}

struct QuickNoteFilingRequest: Identifiable {
    let id = UUID()
    let libraryPath: String
    let choices: [QuickNoteFilingChoice]
    let hasOmittedDuplicates: Bool
}

/// Match the caption people actually see, including the date's minute-level
/// formatting. Distinct files with the same caption need their filename too.
struct QuickNoteFilingChoice: Identifiable {
    let note: MeetingNote
    let dateLabel: String
    let disambiguatingFilename: String?

    var id: LibraryNoteIdentity { note.libraryIdentity }
    var title: String { note.title.isEmpty ? "Untitled note" : note.title }
    var accessibilityLabel: String {
        let destination = "Add to \(title), \(dateLabel)"
        return disambiguatingFilename.map { "\(destination), file \($0)" } ?? destination
    }

    static func choices(for notes: [MeetingNote]) -> [Self] {
        let captions = notes.map {
            Caption(title: $0.title.isEmpty ? "Untitled meeting" : $0.title,
                    date: $0.startedAt.formatted(date: .abbreviated, time: .shortened))
        }
        let counts = Dictionary(grouping: captions, by: { $0 }).mapValues(\.count)
        return zip(notes, captions).map { note, caption in
            Self(note: note, dateLabel: caption.date,
                 disambiguatingFilename: counts[caption, default: 0] > 1
                    ? note.fileURL?.lastPathComponent : nil)
        }
    }

    private struct Caption: Hashable {
        let title: String
        let date: String
    }
}

/// Saves when the window is closed with its own button rather than through the
/// controller.
@MainActor
final class QuickNoteWindowDelegate: NSObject, NSWindowDelegate {
    var onClose: (@MainActor () -> Void)?
    var onShouldClose: (@MainActor () -> Bool)?

    /// `windowWillClose` is too late to object: by then the window is going
    /// whatever anyone thinks. A save that failed has to be able to keep the
    /// panel on screen, so the question is asked here instead.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onShouldClose?() ?? true
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

/// Names a spoken note from its own first words.
enum NoteTitleGenerator {
    static func title(for body: String) -> String {
        let fallback = "Spoken note"
        let sentences = body
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { ".!?".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Reuses the meeting title heuristics so a note and a meeting are named
        // by the same taste, then falls back to the opening words when the note
        // is too short for them to find anything.
        let generated = MeetingTitleGenerator.heuristicTitle(
            from: sentences,
            fallbackTitle: fallback
        )
        guard generated == fallback else { return generated }

        let words = body.split(whereSeparator: \.isWhitespace).prefix(8)
        guard !words.isEmpty else { return fallback }
        let opening = words.joined(separator: " ")
            .trimmingCharacters(
                in: CharacterSet.punctuationCharacters
                    .union(.whitespacesAndNewlines)
            )
        guard let first = opening.first else { return fallback }
        return String(first).uppercased() + opening.dropFirst()
    }
}
