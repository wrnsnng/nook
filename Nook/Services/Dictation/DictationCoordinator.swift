import AVFoundation
import AppKit
import Combine
import Foundation

enum DictationPhase: Equatable {
    case idle
    case preparing
    case listening
    case refining
    case failed(String)

    var isActive: Bool {
        switch self {
        case .preparing, .listening, .refining: true
        case .idle, .failed: false
        }
    }
}

/// How long one dictation may hold the microphone open.
///
/// Hold-to-talk ends on key-up, and macOS Secure Input can swallow that key-up
/// entirely: the release never arrives, nothing calls `finish()`, and the
/// microphone stays live until Nook quits. A ceiling turns that into a
/// finished dictation carrying the words the user actually said.
struct DictationSessionCeilings: Sendable, Equatable {
    /// Hold and toggle. Long enough for a genuinely long dictation, short
    /// enough that a lost key-up costs minutes rather than a working day.
    var interactive: Duration
    /// A hands-free pad session is meant to run long and has a visible toggle
    /// to end it, so the same backstop sits much further out.
    var continuous: Duration

    static let standard = DictationSessionCeilings(
        interactive: .seconds(300),
        continuous: .seconds(1800)
    )

    func ceiling(isContinuous: Bool) -> Duration {
        isContinuous ? continuous : interactive
    }

    /// What the indicator says when a ceiling ends a dictation. The number is
    /// derived rather than written out so the sentence cannot drift from the
    /// value actually in force.
    static func expiryMessage(for ceiling: Duration) -> String {
        let minutes = max(
            1,
            Int((Double(ceiling.components.seconds) / 60).rounded())
        )
        return "Dictation stopped after \(minutes) minute"
            + (minutes == 1 ? "" : "s")
            + ". Press the shortcut to start again."
    }
}

/// Owns the dictation feature: the shortcut, the microphone, the recognizer,
/// the optional rewrite, and delivery into the focused text field.
@MainActor
protocol DictationTextInserting: AnyObject {
    func beginRun() -> TextInsertionService.Capability
    func append(_ text: String) -> Bool
    func replaceRun(with text: String) -> Bool
    func pasteOnce(_ text: String) async -> TextInsertionService.PasteOutcome
    func endRun()

    #if DEBUG
    var lastInspection: String { get }
    #endif
}

extension TextInsertionService: DictationTextInserting {}

@MainActor
final class DictationCoordinator: ObservableObject {
    @Published private(set) var phase: DictationPhase = .idle
    /// The recognizer's current in-progress guess, shown in the indicator only.
    @Published private(set) var volatileText = ""
    @Published private(set) var audioLevel: Float = 0
    /// Set when the shortcut could not be claimed, so Settings can say so.
    @Published private(set) var shortcutError: String?

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            if !isEnabled {
                cancel()
            }
            applyShortcutRegistration()
        }
    }

    @Published var style: DictationStyle {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: Keys.style) }
    }

    @Published var customPrompt: String {
        didSet {
            UserDefaults.standard.set(customPrompt, forKey: Keys.customPrompt)
        }
    }

    @Published var activation: DictationActivation {
        didSet {
            UserDefaults.standard.set(activation.rawValue, forKey: Keys.activation)
        }
    }

    @Published private(set) var shortcut: DictationShortcut

    private let monitor = GlobalShortcutMonitor()
    private let registersShortcut: Bool
    private let audio: any DictationAudioCapturing
    private let recognizer: any DictationRecognizing
    private let insertion: any DictationTextInserting
    private let refiner = DictationRefiner()

    private var capability: TextInsertionService.Capability = .unavailable
    private var spokenChunks: [String] = []
    private var insertedAnything = false
    private var streamingFailed = false
    private var streamedChunkCount = 0
    private var isFinishing = false
    /// The style in force for the current session: the global choice, or a
    /// per-app override when the frontmost app has one. Resolved at begin so
    /// an app switch mid-sentence cannot change how words are treated.
    private var sessionStyle: DictationStyle = .cleanUp
    private var startTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    /// Distinguishes one dictation from the next. A start that is still setting
    /// up when its session is abandoned cannot tell from `phase` alone whether
    /// a later `.preparing` belongs to it or to a newer run.
    private var sessionID = 0
    /// A hands-free pad session: each finished utterance starts the next
    /// listening window by itself until something explicit ends it.
    private var isContinuousSession = false
    /// Polls for Accessibility access while a registration is waiting on it.
    private var trustWatch: Task<Void, Never>?
    /// Ends a dictation that has outlived its ceiling.
    private var sessionWatchdog: Task<Void, Never>?
    private let ceilings: DictationSessionCeilings
    /// Loudest input seen this dictation, used to tell a silent microphone
    /// apart from speech that simply was not recognised.
    private var peakLevel: Float = 0

    /// Below this the input is silence rather than quiet speech. The level is
    /// already scaled for voice in `DictationAudioSource`, where ordinary
    /// speech sits well above it.
    private static let silenceThreshold: Float = 0.02
    private var localeIdentifier: String
    /// The input check shares the microphone and ScreenCaptureKit. Waiting for
    /// its teardown before opening dictation keeps the two capture paths
    /// mutually exclusive even when a shortcut starts during teardown.
    private let prepareForAudioCapture: (@MainActor () async throws -> Void)?
    /// Set by `AppModel` once the store exists. Dictation works without it;
    /// only the no-text-field path needs it.
    weak var quickNote: QuickNoteController?

    /// A rewrite that has not landed in a couple of seconds is not worth the
    /// wait when the user is mid-sentence in someone else's app.
    private static let refinementTimeout: Double = 6

    /// Long enough for the tap's remaining buffers, short enough that a stalled
    /// audio pipeline cannot hold dictation open.
    private static let captureDrainTimeout: Double = 2

    /// How long a finish waits for setup to complete before giving up on it.
    ///
    /// Setup can genuinely stall: a first dictation in a language installs a
    /// speech asset, and permission prompts sit in front of it. This has to
    /// outlast the recognizer's own asset deadline, or the wait here would
    /// expire while the start was still about to fail with a better sentence.
    private static let startWaitTimeout: Double = 75

    private static let startStalledMessage =
        "Dictation couldn’t get started. Try again."

    init(
        localeIdentifier: String,
        audio: any DictationAudioCapturing = DictationAudioSource(),
        recognizer: any DictationRecognizing = DictationRecognizer(),
        insertion: any DictationTextInserting = TextInsertionService(),
        registersShortcut: Bool = true,
        ceilings: DictationSessionCeilings = .standard,
        prepareForAudioCapture: (@MainActor () async throws -> Void)? = nil
    ) {
        let defaults = UserDefaults.standard
        self.ceilings = ceilings
        self.registersShortcut = registersShortcut
        self.prepareForAudioCapture = prepareForAudioCapture
        self.localeIdentifier = localeIdentifier
        self.isEnabled = defaults.bool(forKey: Keys.enabled)
        self.style = defaults.string(forKey: Keys.style)
            .flatMap(DictationStyle.init(rawValue:)) ?? .cleanUp
        self.customPrompt = defaults.string(forKey: Keys.customPrompt)
            ?? DictationStyle.defaultCustomPrompt
        self.activation = defaults.string(forKey: Keys.activation)
            .flatMap(DictationActivation.init(rawValue:)) ?? .hold
        self.shortcut = defaults.data(forKey: Keys.shortcut)
            .flatMap { try? JSONDecoder().decode(DictationShortcut.self, from: $0) }
            ?? .default
        self.audio = audio
        self.recognizer = recognizer
        self.insertion = insertion

        monitor.onPress = { [weak self] in self?.shortcutPressed() }
        monitor.onRelease = { [weak self] in self?.shortcutReleased() }

        audio.onLevel = { [weak self] level in
            self?.audioLevel = level
            self?.peakLevel = max(self?.peakLevel ?? 0, level)
        }
        recognizer.onVolatile = { [weak self] text in
            self?.volatileText = text
        }
        recognizer.onFinalized = { [weak self] text in
            self?.acceptFinalized(text)
        }
        recognizer.onError = { [weak self] message in
            self?.fail(message)
        }
        recognizer.onEnded = { [weak self] in
            self?.endBecauseRecognizerStopped()
        }

        if registersShortcut {
            applyShortcutRegistration()
        }

        // A modifier-only shortcut cannot register until Accessibility is
        // granted, and granting happens in System Settings — so the moment the
        // user comes back is the only signal that the shortcut can now be
        // claimed. Without this it sits there looking configured and silently
        // does nothing until it is set again.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.retryShortcutRegistrationIfNeeded()
            }
        }
    }

    private func retryShortcutRegistrationIfNeeded() {
        guard isEnabled, shortcutError != nil else { return }
        applyShortcutRegistration()
    }

    /// Kept in step with the meeting language rather than given a second
    /// setting; one "spoken language" choice is enough for one app.
    func updateLocale(_ identifier: String) {
        localeIdentifier = identifier
    }

    func setShortcut(_ shortcut: DictationShortcut) {
        self.shortcut = shortcut
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: Keys.shortcut)
        }
        applyShortcutRegistration()
    }

    var needsAccessibilityPermission: Bool {
        isEnabled && !TextInsertionService.isTrusted
    }

    func requestAccessibilityPermission() {
        TextInsertionService.requestTrust()
    }

    func openAccessibilitySettings() {
        TextInsertionService.openAccessibilitySettings()
    }

    // MARK: - Shortcut

    private func applyShortcutRegistration() {
        shortcutError = nil
        trustWatch?.cancel()
        trustWatch = nil

        guard registersShortcut else { return }

        guard isEnabled else {
            monitor.unregister()
            return
        }
        do {
            try monitor.register(shortcut)
        } catch {
            shortcutError = error.localizedDescription
            watchForAccessibilityGrant()
        }
    }

    /// Waits for Accessibility access to appear, then claims the shortcut.
    ///
    /// A modifier-only shortcut cannot be registered until macOS trusts Nook,
    /// and granting happens in System Settings. Retrying when Nook next becomes
    /// active is not enough: the user grants access and returns to whatever they
    /// were doing, so a menu-bar app may not be activated for hours. The
    /// shortcut would appear configured and quietly do nothing, which is exactly
    /// how this looked in testing.
    private func watchForAccessibilityGrant() {
        guard shortcut.isModifierOnly, !TextInsertionService.isTrusted else {
            return
        }
        trustWatch?.cancel()
        trustWatch = Task { @MainActor [weak self] in
            // Bounded, because this covers the minutes around a visit to System
            // Settings. Anything later is picked up when Nook next becomes
            // active, which is a fine backstop once the urgency has passed.
            for _ in 0..<Self.trustWatchAttempts {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                guard let self, self.isEnabled else { return }
                guard TextInsertionService.isTrusted else { continue }
                self.trustWatch = nil
                self.applyShortcutRegistration()
                return
            }
        }
    }

    /// Two seconds apart, so about five minutes in total.
    private static let trustWatchAttempts = 150

    private func shortcutPressed() {
        // During a hands-free pad session the shortcut means stop, in both
        // activation modes: the session exists precisely to not need the key,
        // so pressing it is an unambiguous end.
        if phase.isActive, isContinuousSession {
            stopContinuousSession()
            return
        }
        switch activation {
        case .hold:
            begin()
        case .toggle:
            if phase.isActive {
                finish()
            } else {
                begin()
            }
        }
    }

    private func shortcutReleased() {
        guard activation == .hold else { return }
        finish()
    }

    // MARK: - Lifecycle

    private func begin() {
        guard isEnabled, !phase.isActive else { return }

        phase = .preparing
        volatileText = ""
        resetRunState()
        isFinishing = false

        // A per-app override, when one exists, wins for this session only.
        // The global choice stays untouched for everywhere else.
        let frontmostID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let override = DictationStyle.override(forBundleID: frontmostID) {
            sessionStyle = override
        } else {
            sessionStyle = style
        }

        capability = insertion.beginRun()
        // Keep dictating into the note only while the user is actually in it.
        //
        // Testing for the window merely existing meant that a note left open
        // in a corner captured every dictation from then on, including ones
        // aimed at a text field in another app entirely. The note floats and
        // stays open across app switches by design, so its presence says
        // nothing about where the words are meant to go. Focus does.
        if quickNote?.isFrontmost == true {
            capability = .noTextField
        }
        #if DEBUG
        NookDebugLog.write("[dictation] begin — capability: \(capability), frontmost: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"), \(insertion.lastInspection)")
        #endif

        guard capability != .unavailable else {
            phase = .idle
            requestAccessibilityPermission()
            fail("Nook needs Accessibility access to type into other apps.")
            return
        }

        // A run that starts in a password field ends here, before the
        // microphone is ever opened. The words would have nowhere to go: not
        // the field, and not the pad either, which is a file on disk. Refusing
        // now rather than after the sentence also means nothing is recognised
        // and nothing is held in memory.
        guard capability != .secureField else {
            phase = .idle
            fail(Self.secureFieldMessage)
            return
        }

        // A note is deliberately not opened yet.
        //
        // Where the words belong is decided when they are ready, not when the
        // shortcut goes down. Opening a window the instant someone starts
        // speaking tells them the feature has failed before they have finished
        // their sentence, and it is a guess made at the worst possible moment:
        // an accessibility tree that a web view has not built yet looks
        // identical to no text field at all. Waiting costs nothing and gives
        // that tree the length of the sentence to appear.

        sessionID += 1
        let session = sessionID
        NookEventLog.write(.dictationStarted)
        startSessionWatchdog(for: session)
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.recognizer.start(
                    localeIdentifier: self.localeIdentifier
                )
                // `start()` can outlive cancellation while Speech finishes an
                // asset request. Check before touching the shared audio and
                // insertion services so a late old start cannot open or tear
                // down the resources belonging to a newer session.
                guard self.sessionID == session, self.phase == .preparing else {
                    return
                }
                try await self.prepareForAudioCapture?()
                try Task.checkCancellation()
                guard self.sessionID == session, self.phase == .preparing else {
                    return
                }
                try self.audio.start { [weak self] buffer in
                    self?.recognizer.ingest(buffer)
                }
            } catch {
                guard self.sessionID == session, self.phase == .preparing else {
                    return
                }
                self.fail(error.localizedDescription)
                return
            }

            // A quick tap releases the shortcut before setup finishes. The
            // microphone and recognizer are already live by then, so they have
            // to be torn down here rather than left running silently.
            //
            // Cancellation already tore down the old run, and this stale task
            // must not tear down resources for a newer one.
            guard self.sessionID == session, self.phase == .preparing else {
                return
            }
            self.phase = .listening
        }
    }

    private func finish() {
        guard phase.isActive, !isFinishing else { return }
        isFinishing = true
        sessionWatchdog?.cancel()
        sessionWatchdog = nil
        let session = sessionID

        finishTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.sessionID == session {
                    self.finishTask = nil
                }
            }
            // Starting and stopping must not interleave: a release during
            // setup would otherwise race the recognizer's own start.
            //
            // Bounded, because setup is not guaranteed to finish. A speech
            // asset download that never completes, or a permission prompt
            // nobody answers, would otherwise leave this awaiting forever with
            // the microphone already live and no way to stop it.
            let started: Void? = await withDeadline(
                seconds: Self.startWaitTimeout
            ) { [weak self] () -> Void in
                await self?.startTask?.value
            }
            // Cancellation resolves the deadline immediately. It is not a
            // startup failure, and the session may already have been replaced
            // by a newer one by the time this continuation runs. In either
            // case the stale finisher must not call `fail()`, whose teardown
            // would stop the new run and clear its insertion target.
            guard !Task.isCancelled, self.sessionID == session else {
                if self.sessionID == session {
                    self.isFinishing = false
                }
                return
            }
            // Cleared only once the wait succeeded: `fail` is what cancels a
            // start that is still running, and it cannot cancel a handle this
            // has already dropped.
            guard started != nil else {
                self.fail(Self.startStalledMessage)
                return
            }
            self.startTask = nil

            guard
                !Task.isCancelled,
                self.sessionID == session,
                self.phase.isActive
            else {
                if self.sessionID == session {
                    self.isFinishing = false
                }
                return
            }
            // Draining rather than dropping: the last buffers hold the end of
            // the final word. Bounded because this chain is holding the user's
            // keyboard — every other await here already has a deadline, and
            // this one should not be the exception that wedges dictation.
            _ = await withDeadline(seconds: Self.captureDrainTimeout) {
                [audio] () -> Void in
                await audio.finishCapturing()
            }
            guard !Task.isCancelled, self.sessionID == session else { return }
            self.audioLevel = 0
            await self.recognizer.finish()
            guard !Task.isCancelled, self.sessionID == session else { return }
            self.volatileText = ""
            await self.deliver()
            if self.phase == .idle {
                NookEventLog.write(.dictationFinished)
            }
        }
    }

    /// Starts the backstop that ends a dictation which has run past its
    /// ceiling. One per session, so a stale one cannot end a newer run.
    private func startSessionWatchdog(for session: Int) {
        sessionWatchdog?.cancel()
        // Read from the pad as well as the session flag: a hands-free session
        // clears the flag before opening its next listening window, and those
        // windows belong to the same long-running capture.
        let ceiling = ceilings.ceiling(
            isContinuous: isContinuousSession || quickNote?.isContinuous == true
        )
        sessionWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: ceiling)
            guard
                !Task.isCancelled,
                let self,
                self.sessionID == session,
                self.phase.isActive
            else {
                return
            }
            self.endBecauseCeilingPassed(
                message: DictationSessionCeilings.expiryMessage(for: ceiling)
            )
        }
    }

    /// Ends a dictation that has held the microphone for longer than allowed.
    ///
    /// The words already heard are delivered rather than dropped. The ceiling
    /// exists because a key release went missing, which is not the user's
    /// mistake and not a reason to lose their sentence.
    private func endBecauseCeilingPassed(message: String) {
        guard phase != .preparing else {
            // Never reached listening, so there is nothing to deliver, and the
            // start it is still waiting on is exactly what has to be cancelled.
            fail(message)
            return
        }
        guard !isFinishing else { return }
        finish()

        // Said through the indicator once the delivery has settled. `.failed`
        // carries the only sentence the indicator can show, and by this point
        // the run has already ended cleanly, so this is a notice rather than a
        // failure. A delivery that ended in a real failure keeps its own, more
        // specific message.
        Task { @MainActor [weak self] in
            await self?.finishTask?.value
            guard let self, self.phase == .idle else { return }
            self.showNotice(message)
        }
    }

    /// Puts a sentence in the indicator without tearing anything down.
    private func showNotice(_ message: String) {
        phase = .failed(message)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.phase == .failed(message) else { return }
            self.phase = .idle
        }
    }

    /// The recognizer stopped by itself while the user was still speaking.
    ///
    /// A results stream that ends without an error leaves the microphone live
    /// and no more words coming. Everything heard up to that point is real, so
    /// the run is finished normally rather than failed.
    private func endBecauseRecognizerStopped() {
        guard phase.isActive, !isFinishing else { return }
        finish()
    }

    func cancel() {
        guard phase.isActive || isFinishing || isFailed else { return }
        sessionID += 1
        isFinishing = false
        isContinuousSession = false
        sessionWatchdog?.cancel()
        sessionWatchdog = nil
        startTask?.cancel()
        startTask = nil
        finishTask?.cancel()
        finishTask = nil
        audio.stop()
        recognizer.cancel()
        insertion.endRun()
        audioLevel = 0
        volatileText = ""
        resetRunState()
        // Set last: a start still in flight reads this to decide it is no
        // longer wanted and tears its own microphone session down.
        phase = .idle
    }

    // MARK: - Text

    private func acceptFinalized(_ text: String) {
        // A recognizer may publish one last result after cancellation. Once a
        // pad has closed or discarded its session, that result has no valid
        // destination and must not be allowed to present the pad again.
        guard phase.isActive || isFinishing else { return }
        let cleaned = sessionStyle == .cleanUp ? DisfluencyFilter.clean(text) : text

        #if DEBUG
        // `DisfluencyFilter` assumes the recognizer capitalizes a letter that
        // was read out as a letter, which is undocumented and decides whether
        // "the code is A A 7 3" keeps both letters. Dictate a code with this
        // build and compare the two lines to settle it against real output.
        if text != cleaned {
            NookDebugLog.write("[dictation] heard: \(text)")
            NookDebugLog.write("[dictation] typed: \(cleaned)")
        }
        #endif

        guard !cleaned.isEmpty else { return }
        // Spoken formatting commands are exact substitutions applied before
        // anything else sees the chunk, so every delivery path honours them.
        let spoken = DictationFormatting.apply(to: cleaned)
        guard !spoken.isEmpty else { return }
        spokenChunks.append(spoken)

        // Rewriting styles deliberately put nothing in the field while the user
        // is speaking. Streaming the raw words and swapping them afterwards
        // showed unpolished text landing instantly and then rearranging itself,
        // which reads as the feature misbehaving rather than working. The
        // indicator carries the live words instead, and the field receives the
        // finished sentence once.
        // Already in the note: it is Nook's own surface, so the words go
        // straight in. Otherwise nothing is delivered mid-sentence, and the
        // destination is settled once the user stops talking.
        if capability == .noTextField {
            if quickNote?.isFrontmost == true {
                quickNote?.append(spoken)
            }
            return
        }

        guard capability == .streaming, sessionStyle.streamsLive, !streamingFailed
        else {
            return
        }
        // A break already provides the separation; a space before it would
        // strand whitespace at the end of the previous paragraph.
        let needsSpace = !spoken.hasPrefix("\n")
        let appended = insertion.append(
            (insertedAnything && needsSpace ? " " : "") + spoken
        )
        #if DEBUG
        NookDebugLog.write("[dictation] append \(appended ? "ok" : "FAILED"): \(spoken)")
        #endif
        guard appended else {
            // The field stopped accepting writes mid-sentence. Silently
            // dropping the rest would leave a sentence missing words with no
            // sign anything went wrong, so streaming stops here and everything
            // from this chunk on is delivered together at the end.
            streamingFailed = true
            streamedChunkCount = spokenChunks.count - 1
            return
        }
        insertedAnything = true
        streamedChunkCount = spokenChunks.count
    }

    /// Clears everything scoped to a single dictation. Kept in one place so a
    /// new piece of per-run state cannot be added to one reset and not another.
    private func resetRunState() {
        peakLevel = 0
        spokenChunks = []
        insertedAnything = false
        streamingFailed = false
        streamedChunkCount = 0
    }

    /// The chunks that never made it into the field, in order.
    private var undeliveredChunks: [String] {
        guard streamingFailed, streamedChunkCount < spokenChunks.count else {
            return []
        }
        return Array(spokenChunks[streamedChunkCount...])
    }

    private var spokenText: String {
        spokenChunks.joined(separator: " ")
    }

    private func deliver() async {
        let deliverySession = sessionID
        let spoken = spokenText
        #if DEBUG
        NookDebugLog.write("[dictation] deliver — capability: \(capability), streamingFailed: \(streamingFailed), chunks: \(spokenChunks.count), peak: \(peakLevel), spoken: \"\(spoken)\"")
        #endif
        guard !spoken.isEmpty else {
            // Nothing was recognised. Silence at the microphone and speech that
            // merely failed to recognise are different problems with different
            // fixes, and the difference is invisible from the outside: the
            // indicator says "Listening" either way, then closes with nothing.
            // A muted or switched-off input is by far the more common of the
            // two, and the only one the user can act on.
            fail(
                peakLevel < Self.silenceThreshold
                    ? "Nook didn’t hear anything. Check that your microphone is on."
                    : "Nook couldn’t make out any words."
            )
            return
        }

        var finalText = spoken
        if sessionStyle.usesLanguageModel {
            phase = .refining
            let outcome = await withDeadline(
                seconds: Self.refinementTimeout
            ) { [refiner, style = sessionStyle, customPrompt] () -> DictationRefiner.Outcome in
                await refiner.refine(
                    spoken: spoken,
                    style: style,
                    customPrompt: customPrompt
                )
            }
            if case .refined(let refined)? = outcome {
                finalText = refined
            }
            guard !Task.isCancelled, sessionID == deliverySession else {
                return
            }
        }

        switch capability {
        case .streaming where !streamingFailed && !sessionStyle.streamsLive:
            // Nothing was written while the user spoke, so the finished
            // sentence goes in now, in one piece.
            guard insertion.append(finalText) else {
                switch await deliverByPasting(
                    finalText,
                    padText: finalText,
                    failureMessage: "Nook couldn’t type into that app.",
                    session: deliverySession
                ) {
                case .delivered:
                    guard !Task.isCancelled, sessionID == deliverySession else {
                        return
                    }
                    concludeDelivery()
                case .failed(let message):
                    fail(message)
                }
                return
            }
        case .streaming where !streamingFailed:
            // Verbatim and clean-up are already in the field verbatim, and
            // that is the final text, so nothing more is owed.
            if finalText != spoken {
                _ = insertion.replaceRun(with: finalText)
            }
        case .streaming:
            // Streaming broke partway. Whatever was already written stays; the
            // rest goes in through the pasteboard so no words are lost.
            //
            // A rewrite is deliberately abandoned here even for the model
            // styles. It covers the whole utterance, and part of that utterance
            // is already in the document beyond Nook's ability to revise
            // safely — `replaceRun` cannot verify a run it lost track of. The
            // user's own complete words beat a polished sentence spliced onto a
            // fragment.
            let remainder = undeliveredChunks.joined(separator: " ")
            if !remainder.isEmpty {
                // The pasted remainder carries a leading space so it joins what
                // is already in the field. A note starts empty, so it does not.
                let delivery = await deliverByPasting(
                    " " + remainder,
                    padText: remainder,
                    failureMessage: "Nook couldn’t finish typing into that app.",
                    session: deliverySession
                )
                #if DEBUG
                NookDebugLog.write("[dictation] remainder paste \(delivery)")
                #endif
                if case .failed(let message) = delivery {
                    fail(message)
                    return
                }
            }
        case .pasteOnly:
            let delivery = await deliverByPasting(
                finalText,
                padText: finalText,
                failureMessage: "Nook couldn’t paste into that app.",
                session: deliverySession
            )
            #if DEBUG
            NookDebugLog.write("[dictation] paste \(delivery)")
            #endif
            if case .failed(let message) = delivery {
                fail(message)
                return
            }
        case .noTextField:
            switch await deliverWithoutAKnownField(
                finalText,
                spoken: spoken,
                session: deliverySession
            ) {
            case .delivered:
                break
            case .abandoned:
                return
            case .failed(let message):
                fail(message)
                return
            }
        case .secureField, .unavailable:
            // Both are refused in `begin`, so neither reaches a delivery.
            break
        }

        // Cleanup is explicit rather than deferred because the continuous
        // restart below opens a new run: a defer would tear that fresh run's
        // insertion context down right after begin() built it. Every early
        // exit above goes through fail() or concludeDelivery(), which perform
        // the same teardown.
        guard !Task.isCancelled, sessionID == deliverySession else { return }
        concludeDelivery()
    }

    /// Ends a successful delivery: run-scoped state goes, the phase settles,
    /// and a hands-free pad session opens its next listening window.
    private func concludeDelivery() {
        insertion.endRun()
        sessionWatchdog?.cancel()
        sessionWatchdog = nil
        isFinishing = false
        resetRunState()
        phase = .idle
        restartIfContinuous()
    }

    /// Opens the next listening window of a hands-free pad session.
    ///
    /// Only a delivery that actually landed in the pad sets the session flag,
    /// so dictation aimed at another app's field never starts looping.
    private func restartIfContinuous() {
        guard isContinuousSession else { return }
        isContinuousSession = false
        guard quickNote?.isFrontmost == true,
              quickNote?.isContinuous == true else { return }
        begin()
    }

    /// Starts hands-free capture from the pad's toggle, when idle.
    func startContinuousSession() {
        isContinuousSession = true
        guard !phase.isActive, isEnabled else { return }
        begin()
    }

    /// Ends hands-free capture from the pad's toggle or the shortcut.
    func stopContinuousSession() {
        isContinuousSession = false
        guard phase.isActive, !isFinishing else { return }
        finish()
    }

    /// Places a finished dictation when no text field was found at the start.
    ///
    /// Focus is looked up a second time here. By now the user has spoken for a
    /// few seconds, which is far longer than a web view needs to build the
    /// accessibility tree it had not built when they pressed the shortcut, so a
    /// field that was invisible then is usually available now. Only when there
    /// is still nowhere to put the words does a note open, which is the case
    /// the note was meant for.
    /// Marks this delivery as pad-bound and keeps listening when the pad asks
    /// for hands-free capture.
    private enum UnknownFieldDelivery {
        case delivered
        case abandoned
        case failed(String)
    }

    private func deliverWithoutAKnownField(
        _ finalText: String,
        spoken: String,
        session: Int
    ) async -> UnknownFieldDelivery {
        guard !Task.isCancelled, sessionID == session else {
            return .abandoned
        }
        if quickNote?.isFrontmost == true {
            isContinuousSession = quickNote?.isContinuous == true
            if finalText != spoken {
                quickNote?.replaceLastDictation(with: finalText, spoken: spoken)
            }
            quickNote?.saveIfNeeded()
            return .delivered
        }

        let second = insertion.beginRun()
        #if DEBUG
        NookDebugLog.write(
            "[dictation] second look, capability: \(second), \(insertion.lastInspection)"
        )
        #endif
        switch second {
        case .streaming:
            guard insertion.append(finalText) else { break }
            return .delivered
        case .pasteOnly:
            // Awaiting here keeps the second-look insertion target alive until
            // `pasteOnce` has re-read focus and posted the paste. Ending the
            // run first clears that target, making every paste-only fallback
            // look like focus moved and routing valid speech to the pad.
            let result = await insertion.pasteOnce(finalText)
            guard !Task.isCancelled, sessionID == session else {
                return .abandoned
            }
            switch result {
            case .pasted:
                return .delivered
            case .refused(.secureField):
                return .failed(Self.secureFieldMessage)
            case .refused(.focusMoved), .failed:
                routeToQuickNotePad(finalText, session: session)
                return .delivered
            }
        case .secureField, .noTextField, .unavailable:
            // A password field found on the second look is not where these
            // words came from: this run started with no field at all, so
            // nothing spoken into it is a password. It is somewhere the words
            // merely must not go, and the pad is the right home, which is the
            // same distinction `pasteRefusal` draws.
            break
        }

        routeToQuickNotePad(finalText, session: session)
        return .delivered
    }

    /// The no-field path: the pad opens holding the words, and saves them.
    private func routeToQuickNotePad(_ text: String, session: Int) {
        guard !Task.isCancelled, sessionID == session else { return }
        quickNote?.present()
        quickNote?.append(text)
        quickNote?.saveIfNeeded()
    }

    private enum PasteDelivery {
        case delivered
        case failed(String)
    }

    /// Pastes `text`, and sends the words to the pad when focus has moved on.
    ///
    /// `padText` is what the pad receives, which is not always what would have
    /// been pasted.
    private func deliverByPasting(
        _ text: String,
        padText: String,
        failureMessage: String,
        session: Int
    ) async -> PasteDelivery {
        let result = await insertion.pasteOnce(text)
        guard !Task.isCancelled, sessionID == session else {
            return .delivered
        }
        switch result {
        case .pasted:
            return .delivered
        case .refused(.focusMoved):
            // The words belong to the field the run started in, and that field
            // no longer has focus. They go somewhere the user can read and move
            // them deliberately rather than into whatever is in front now.
            routeToQuickNotePad(padText, session: session)
            return .delivered
        case .refused(.secureField):
            return .failed(Self.secureFieldMessage)
        case .failed:
            return .failed(failureMessage)
        }
    }

    /// Shown rather than written anywhere: words spoken into a password field
    /// are a secret, and the note pad is a file on disk.
    private static let secureFieldMessage =
        "Nook won’t type into a password field."

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    #if DEBUG
    var isFinishingForTesting: Bool { isFinishing }
    #endif

    private func fail(_ message: String) {
        // Every failure is a terminal lifecycle path, including asynchronous
        // recognizer errors. UI state alone is not cleanup: without this common
        // teardown the audio tap can keep the microphone live after the
        // indicator disappears, and the failed phase then rejects `cancel()`.
        sessionID += 1
        sessionWatchdog?.cancel()
        sessionWatchdog = nil
        startTask?.cancel()
        startTask = nil
        finishTask?.cancel()
        finishTask = nil
        isContinuousSession = false
        audio.stop()
        recognizer.cancel()
        insertion.endRun()
        isFinishing = false
        phase = .failed(message)
        audioLevel = 0
        volatileText = ""
        resetRunState()
        NookEventLog.write(.dictationFailed)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.isFailed else { return }
            self.phase = .idle
        }
    }

    private enum Keys {
        static let enabled = "dictationEnabled"
        static let style = "dictationStyle"
        static let customPrompt = "dictationCustomPrompt"
        static let activation = "dictationActivation"
        static let shortcut = "dictationShortcut"
    }
}
