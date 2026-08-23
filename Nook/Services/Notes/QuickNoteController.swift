import AppKit
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
    @Published var text = ""
    @Published private(set) var isPresenting = false
    @Published private(set) var isWorking = false
    @Published private(set) var message: String?
    @Published private(set) var lastSavedAt: Date?
    /// Whether edits have landed since the last save, so the status line can
    /// say "Saved" only while it is true.
    @Published private(set) var hasUnsavedEdits = false

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
    @Published private(set) var availableEngines: [NoteAssistantEngine] = []

    @Published private(set) var engine: NoteAssistantEngine {
        didSet {
            UserDefaults.standard.set(engine.rawValue, forKey: Keys.engine)
        }
    }

    /// Hands-free capture: after each spoken chunk lands, listening starts
    /// again by itself until the pad is closed, the toggle turns off, or the
    /// dictation shortcut is pressed to stop.
    @Published var isContinuous: Bool {
        didSet {
            UserDefaults.standard.set(isContinuous, forKey: Keys.continuous)
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
        guard engine != self.engine else { return }
        guard engine.leavesTheMac, !hasConsented(to: engine) else {
            self.engine = engine
            return
        }
        guard confirmSending(to: engine) else { return }
        UserDefaults.standard.set(true, forKey: Keys.consent(engine))
        self.engine = engine
    }

    func hasConsented(to engine: NoteAssistantEngine) -> Bool {
        guard engine.leavesTheMac else { return true }
        return UserDefaults.standard.bool(forKey: Keys.consent(engine))
    }

    /// Forgets a previous agreement, so the explanation is shown again.
    func revokeConsent(for engine: NoteAssistantEngine) {
        UserDefaults.standard.removeObject(forKey: Keys.consent(engine))
        if self.engine == engine {
            self.engine = .onDevice
        }
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

        Nothing is sent until you run an action, and only the note you are \
        working on is included: never your recordings, meetings, or other \
        notes.
        """
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

    private let store: MarkdownStore
    private let assistant = NoteAssistant()
    private var panel: NSPanel?
    private let windowDelegate = QuickNoteWindowDelegate()
    private var savedNoteID: UUID?
    /// The file the pad's note already lives in.
    ///
    /// Held because the note is rebuilt from scratch on every save and its
    /// title is regenerated from the words so far. Hands-free capture saves
    /// after each spoken chunk, so a destination derived from the title again
    /// wrote one thought into a new file every few seconds.
    private var savedNoteURL: URL?
    private var startedAt = Date()
    private var saveDebounce: Task<Void, Never>?

    init(store: MarkdownStore) {
        self.store = store
        self.engine = Self.restoredEngine()
        self.isContinuous = UserDefaults.standard.bool(
            forKey: Keys.continuous
        )
    }

    /// The engine to start with, which is not simply the remembered one.
    ///
    /// Consent is the authority, and it is checked here rather than trusted to
    /// have been checked when the choice was made. A stored preference can
    /// outlive the agreement that justified it: written by an earlier version
    /// that had no consent step, restored from a backup, or left behind when
    /// the agreement was withdrawn. Any of those would otherwise mean notes
    /// leaving the Mac on launch with nobody having said yes.
    private static func restoredEngine() -> NoteAssistantEngine {
        let defaults = UserDefaults.standard
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
        if !isPresenting {
            text = ""
            savedNoteID = nil
            savedNoteURL = nil
            message = nil
            hasUnsavedEdits = false
            startedAt = Date()
            // Hands-free is a session, not a preference. The stored value
            // outlives the session that set it, so restoring it would show a
            // ticked box with nothing listening. Nook also must not open the
            // microphone because a pad appeared: the tick follows a session
            // the user starts here, and starts off every time.
            isContinuous = false
            isPresenting = true
            showWindow()
            refreshEngines()
        }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Appends a finalized chunk while the user is still speaking.
    func append(_ chunk: String) {
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

    /// Swaps the words just dictated for their rewritten form.
    ///
    /// Matched by content rather than position, so anything the user typed
    /// themselves in the meantime is left exactly where it is.
    func replaceLastDictation(with rewritten: String, spoken: String) {
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
        // catch a thought.
        saveDebounce?.cancel()
        saveDebounce = nil
        saveIfNeeded()
        hasUnsavedEdits = false
        isPresenting = false
        panel?.orderOut(nil)
        panel = nil
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
            self.hasUnsavedEdits = false
        }
    }

    /// Saves and closes, from the pad's own button or its keyboard shortcut.
    func done() {
        close()
    }

    /// Throws the note away, asking first when there is enough of it to miss.
    ///
    /// A debounced save may already have written the file, so discarding has
    /// to delete what was written rather than merely closing the window.
    func discardWithConfirmation() {
        guard wordCount <= Self.discardConfirmationWordCount
            || confirmDiscard()
        else { return }
        discard()
    }

    func discard() {
        saveDebounce?.cancel()
        saveDebounce = nil
        if let savedNoteID,
           let saved = store.notes.first(where: { $0.id == savedNoteID }) {
            _ = store.delete(saved)
        }
        savedNoteID = nil
        savedNoteURL = nil
        text = ""
        lastSavedAt = nil
        hasUnsavedEdits = false
        message = nil
        isPresenting = false
        panel?.orderOut(nil)
        panel = nil
    }

    private func confirmDiscard() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard this note?"
        alert.informativeText =
            "These words are not kept anywhere else, and this cannot be undone."
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
        guard !body.isEmpty else { return nil }

        let note = MeetingNote(
            id: savedNoteID ?? UUID(),
            kind: .spoken,
            title: NoteTitleGenerator.title(for: body),
            startedAt: startedAt,
            endedAt: Date(),
            sourceApp: "Spoken note",
            summary: body,
            fileURL: savedNoteURL
        )
        do {
            let saved = try store.save(note)
            savedNoteID = saved.id
            savedNoteURL = saved.fileURL
            lastSavedAt = Date()
            message = nil
            return saved
        } catch {
            message = "Couldn’t save this note: \(error.localizedDescription)"
            return nil
        }
    }

    func saveAndOpenInLibrary() {
        guard let note = saveIfNeeded() else { return }
        isPresenting = false
        panel?.orderOut(nil)
        panel = nil
        AppModel.shared.openLibrary(noteID: note.id)
    }

    /// Files the pad's words into a meeting note's personal notes instead of
    /// saving them as their own spoken note.
    ///
    /// The buffer joins whatever personal notes exist with a blank line
    /// between, so neither half is rewritten; the meeting's own transcript and
    /// summary are untouched. Closing without saving-as-spoken keeps one
    /// thought in one place rather than two copies.
    func fileIntoMeeting(_ target: MeetingNote) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        do {
            let existing = target.personalNotes
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let joined = existing.isEmpty
                ? body
                : "\(existing)\n\n\(body)"
            _ = try store.updatePersonalNotes(joined, for: target)
            text = ""
            savedNoteID = nil
            savedNoteURL = nil
            lastSavedAt = Date()
            message = nil
            isPresenting = false
            panel?.orderOut(nil)
            panel = nil
        } catch {
            message = "Couldn’t file into that meeting: \(error.localizedDescription)"
        }
    }

    /// Meetings the filing menu can offer, newest first.
    var recentMeetingTargets: [MeetingNote] {
        store.notes.filter { $0.kind == .meeting }.prefix(5).map { $0 }
    }

    /// Starts a checklist line at the cursor from the toolbar or keyboard.
    func insertChecklistLine() {
        editorPort.insertLineStarting(with: "- [ ] ")
    }

    // MARK: - Assistance

    func refreshEngines() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let engines = await self.assistant.availableEngines()
            self.availableEngines = engines
            // A previously chosen engine can disappear when a tool is removed.
            // Falling back must never land on one that sends notes away, so an
            // agreement is required even when Nook picks for the user.
            if !engines.contains(self.engine) {
                self.engine = engines.first(where: { !$0.leavesTheMac })
                    ?? engines.first(where: { self.hasConsented(to: $0) })
                    ?? .onDevice
            }
        }
    }

    func run(_ action: NoteAction) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !isWorking else { return }

        isWorking = true
        runningAction = action
        message = nil
        let engine = self.engine
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isWorking = false
                self.runningAction = nil
            }
            do {
                let result = try await self.assistant.run(
                    action,
                    on: body,
                    using: engine
                )
                self.apply(result, for: action)
            } catch {
                self.message = error.localizedDescription
            }
        }
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
            // Appended under a heading so the note keeps the spoken words and
            // the derived material side by side, rather than one replacing the
            // other silently.
            text += "\n\n## \(action.title)\n\n\(result)"
            saveIfNeeded()
        }
    }

    var wordCount: Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

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
        panel.delegate = windowDelegate
        self.panel = panel
    }

    private static let frameAutosaveName = "QuickNote"

    private enum Keys {
        static let engine = "quickNoteEngine"
        static let continuous = "quickNoteContinuous"

        static func consent(_ engine: NoteAssistantEngine) -> String {
            "quickNoteConsent.\(engine.rawValue)"
        }
    }
}

/// Saves when the window is closed with its own button rather than through the
/// controller.
@MainActor
final class QuickNoteWindowDelegate: NSObject, NSWindowDelegate {
    var onClose: (@MainActor () -> Void)?

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
