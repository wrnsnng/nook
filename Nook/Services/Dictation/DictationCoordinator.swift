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

/// Owns the dictation feature: the shortcut, the microphone, the recognizer,
/// the optional rewrite, and delivery into the focused text field.
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
    private let audio = DictationAudioSource()
    private let recognizer = DictationRecognizer()
    private let insertion = TextInsertionService()
    private let refiner = DictationRefiner()

    private var capability: TextInsertionService.Capability = .unavailable
    private var spokenChunks: [String] = []
    private var insertedAnything = false
    private var streamingFailed = false
    private var streamedChunkCount = 0
    private var isFinishing = false
    private var startTask: Task<Void, Never>?
    /// Distinguishes one dictation from the next. A start that is still setting
    /// up when its session is abandoned cannot tell from `phase` alone whether
    /// a later `.preparing` belongs to it or to a newer run.
    private var sessionID = 0
    private var localeIdentifier: String
    /// Set by `AppModel` once the store exists. Dictation works without it;
    /// only the no-text-field path needs it.
    weak var quickNote: QuickNoteController?

    /// A rewrite that has not landed in a couple of seconds is not worth the
    /// wait when the user is mid-sentence in someone else's app.
    private static let refinementTimeout: Double = 6

    /// Long enough for the tap's remaining buffers, short enough that a stalled
    /// audio pipeline cannot hold dictation open.
    private static let captureDrainTimeout: Double = 2

    init(localeIdentifier: String) {
        let defaults = UserDefaults.standard
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

        monitor.onPress = { [weak self] in self?.shortcutPressed() }
        monitor.onRelease = { [weak self] in self?.shortcutReleased() }

        audio.onLevel = { [weak self] level in
            self?.audioLevel = level
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

        applyShortcutRegistration()

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
        guard isEnabled else {
            monitor.unregister()
            return
        }
        do {
            try monitor.register(shortcut)
        } catch {
            shortcutError = error.localizedDescription
        }
    }

    private func shortcutPressed() {
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

        capability = insertion.beginRun()
        // Already capturing into a note: keep going there rather than
        // re-inspecting focus, which is now the note's own text view.
        if quickNote?.isPresenting == true {
            capability = .noTextField
        }
        #if DEBUG
        DictationDebugLog.write("[dictation] begin — capability: \(capability), frontmost: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"), \(insertion.lastInspection)")
        #endif

        guard capability != .unavailable else {
            phase = .idle
            requestAccessibilityPermission()
            fail("Nook needs Accessibility access to type into other apps.")
            return
        }

        // Nothing can take the words, so they get somewhere of their own. This
        // is the path that lets a thought be captured without opening an app, a
        // file, or a window first.
        if capability == .noTextField {
            quickNote?.present()
        }

        sessionID += 1
        let session = sessionID
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.recognizer.start(
                    localeIdentifier: self.localeIdentifier
                )
                try self.audio.start { [weak self] buffer in
                    self?.recognizer.ingest(buffer)
                }
            } catch {
                self.audio.stop()
                self.recognizer.cancel()
                self.insertion.endRun()
                self.fail(error.localizedDescription)
                return
            }

            // A quick tap releases the shortcut before setup finishes. The
            // microphone and recognizer are already live by then, so they have
            // to be torn down here rather than left running silently.
            //
            // The session check is what makes this correct rather than merely
            // usually right: cancel-then-restart puts the phase back to
            // `.preparing` for a *newer* run, and this one must not mistake
            // that for its own.
            guard self.sessionID == session, self.phase == .preparing else {
                self.audio.stop()
                self.recognizer.cancel()
                self.insertion.endRun()
                return
            }
            self.phase = .listening
        }
    }

    private func finish() {
        guard phase.isActive, !isFinishing else { return }
        isFinishing = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Starting and stopping must not interleave: a release during
            // setup would otherwise race the recognizer's own start.
            await self.startTask?.value
            self.startTask = nil

            guard self.phase.isActive else {
                self.isFinishing = false
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
            self.audioLevel = 0
            await self.recognizer.finish()
            self.volatileText = ""
            await self.deliver()
        }
    }

    func cancel() {
        guard phase.isActive else { return }
        isFinishing = false
        startTask?.cancel()
        startTask = nil
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
        let cleaned = style == .cleanUp ? DisfluencyFilter.clean(text) : text

        #if DEBUG
        // `DisfluencyFilter` assumes the recognizer capitalizes a letter that
        // was read out as a letter, which is undocumented and decides whether
        // "the code is A A 7 3" keeps both letters. Dictate a code with this
        // build and compare the two lines to settle it against real output.
        if text != cleaned {
            DictationDebugLog.write("[dictation] heard: \(text)")
            DictationDebugLog.write("[dictation] typed: \(cleaned)")
        }
        #endif

        guard !cleaned.isEmpty else { return }
        spokenChunks.append(cleaned)

        // Rewriting styles deliberately put nothing in the field while the user
        // is speaking. Streaming the raw words and swapping them afterwards
        // showed unpolished text landing instantly and then rearranging itself,
        // which reads as the feature misbehaving rather than working. The
        // indicator carries the live words instead, and the field receives the
        // finished sentence once.
        // A note is Nook's own surface, so there is no reason to hold text
        // back: it streams whatever the style produces and the rewrite, when
        // there is one, replaces the whole note at the end.
        if capability == .noTextField {
            quickNote?.append(cleaned)
            return
        }

        guard capability == .streaming, style.streamsLive, !streamingFailed
        else {
            return
        }
        let separator = insertedAnything ? " " : ""
        let appended = insertion.append(separator + cleaned)
        #if DEBUG
        DictationDebugLog.write("[dictation] append \(appended ? "ok" : "FAILED"): \(cleaned)")
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
        defer {
            insertion.endRun()
            isFinishing = false
            resetRunState()
        }

        let spoken = spokenText
        #if DEBUG
        DictationDebugLog.write("[dictation] deliver — capability: \(capability), streamingFailed: \(streamingFailed), chunks: \(spokenChunks.count), spoken: \"\(spoken)\"")
        #endif
        guard !spoken.isEmpty else {
            phase = .idle
            return
        }

        var finalText = spoken
        if style.usesLanguageModel {
            phase = .refining
            let outcome = await withDeadline(
                seconds: Self.refinementTimeout
            ) { [refiner, style, customPrompt] () -> DictationRefiner.Outcome in
                await refiner.refine(
                    spoken: spoken,
                    style: style,
                    customPrompt: customPrompt
                )
            }
            if case .refined(let refined)? = outcome {
                finalText = refined
            }
        }

        switch capability {
        case .streaming where !streamingFailed && !style.streamsLive:
            // Nothing was written while the user spoke, so the finished
            // sentence goes in now, in one piece.
            guard insertion.append(finalText) else {
                let pasted = await insertion.pasteOnce(finalText)
                if !pasted { fail("Nook couldn’t type into that app.") }
                phase = pasted ? .idle : phase
                return
            }
        case .streaming where !streamingFailed:
            // Verbatim and clean-up are already in the field verbatim, and
            // that is the final text, so nothing more is owed.
            if finalText != spoken {
                insertion.replaceRun(with: finalText)
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
                let pasted = await insertion.pasteOnce(" " + remainder)
                #if DEBUG
                DictationDebugLog.write(
                    "[dictation] remainder paste \(pasted ? "ok" : "FAILED")"
                )
                #endif
                guard pasted else {
                    fail("Nook couldn’t finish typing into that app.")
                    return
                }
            }
        case .pasteOnly:
            let pasted = await insertion.pasteOnce(finalText)
            #if DEBUG
            DictationDebugLog.write("[dictation] paste \(pasted ? "ok" : "FAILED")")
            #endif
            guard pasted else {
                fail("Nook couldn’t paste into that app.")
                return
            }
        case .noTextField:
            // Already streamed into the note. A rewrite replaces it wholesale,
            // since the note holds only this dictation.
            if finalText != spoken {
                quickNote?.replaceLastDictation(with: finalText, spoken: spoken)
            }
            quickNote?.saveIfNeeded()
        case .unavailable:
            break
        }

        phase = .idle
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        audioLevel = 0
        volatileText = ""
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
