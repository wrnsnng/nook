import Foundation
import FoundationModels

/// Something a note can be asked to do with itself.
enum NoteAction: String, CaseIterable, Identifiable, Sendable {
    case tidy
    case summarize
    case actionItems
    case expand

    var id: Self { self }

    var title: String {
        switch self {
        case .tidy: "Tidy up"
        case .summarize: "Summarise"
        case .actionItems: "Find actions"
        case .expand: "Expand"
        }
    }

    var symbol: String {
        switch self {
        case .tidy: "wand.and.sparkles"
        case .summarize: "text.append"
        case .actionItems: "checklist"
        case .expand: "arrow.up.left.and.arrow.down.right"
        }
    }

    /// Whether the result replaces the note or is added to it.
    var replacesNote: Bool {
        switch self {
        case .tidy, .expand: true
        case .summarize, .actionItems: false
        }
    }

    /// How far a replacing rewrite may grow before it counts as drift and is
    /// refused in favour of the words already in the note.
    ///
    /// Expanding deliberately develops a rough note into structured prose, so
    /// it may grow much further than tidying, which mostly removes filler.
    /// Beyond the ceiling a result is the model writing its own piece rather
    /// than working on this one. Appending actions never consult this: their
    /// output sits beside the spoken words instead of replacing them.
    var maximumRewriteGrowth: Double {
        switch self {
        case .tidy: DictationOutputGuard.defaultMaximumLengthRatio
        case .expand: 4.0
        case .summarize, .actionItems: 0
        }
    }

    var instruction: String {
        switch self {
        case .tidy:
            """
            Rewrite this spoken note as clear written text. Fix grammar and \
            structure, and group related thoughts. Keep every idea, name, and \
            number exactly as given. Do not add anything that was not said. \
            Output only the rewritten note.
            """
        case .summarize:
            """
            Write two or three sentences capturing what this note is about. \
            Use only what the note says. Output only the summary.
            """
        case .actionItems:
            """
            List the concrete things the speaker committed to doing, one per \
            line, each starting with "- ". Include an owner or date only when \
            stated. If nothing was committed to, output nothing at all.
            """
        case .expand:
            """
            This is a rough spoken note. Rewrite it as a well-organised piece \
            of writing, adding structure and headings where they help. Develop \
            only the ideas already present, never introducing new facts, names, \
            numbers, or claims. Output only the rewritten note.
            """
        }
    }
}

/// Where a note action's thinking happens.
enum NoteAssistantEngine: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Apple's on-device model. Free, private, offline, always available.
    case onDevice
    /// The Claude Code CLI, using the subscription already signed in there.
    case claude
    /// The Codex CLI, likewise.
    case codex

    var id: Self { self }

    var title: String {
        switch self {
        case .onDevice: "On this Mac"
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    var detail: String {
        switch self {
        case .onDevice:
            "Apple Intelligence. Nothing leaves this Mac."
        case .claude:
            "Runs your installed Claude Code with your existing subscription. Note text is sent to Anthropic."
        case .codex:
            "Runs your installed Codex CLI with your existing subscription. Note text is sent to OpenAI."
        }
    }

    /// Whether choosing this engine sends note content off the Mac.
    var leavesTheMac: Bool {
        self != .onDevice
    }

    /// Who receives the note text. Named explicitly wherever this engine is
    /// offered — "Claude" is a product, and the point the user needs to
    /// understand is which company the words reach.
    var provider: String? {
        switch self {
        case .onDevice: nil
        case .claude: "Anthropic"
        case .codex: "OpenAI"
        }
    }

    /// The tool that has to be installed and signed in.
    var toolName: String {
        switch self {
        case .onDevice: "Apple Intelligence"
        case .claude: "Claude Code"
        case .codex: "the Codex CLI"
        }
    }
}

enum NoteAssistantError: LocalizedError {
    case unavailable(NoteAssistantEngine)
    case failed(String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .unavailable(let engine):
            switch engine {
            case .onDevice:
                "Apple Intelligence is not available on this Mac."
            case .claude:
                "Claude Code was not found. Install it and sign in, then try again."
            case .codex:
                "The Codex CLI was not found. Install it and sign in, then try again."
            }
        case .failed(let message):
            message
        case .emptyResult:
            "Nothing came back. Your note is unchanged."
        }
    }
}

/// Runs note actions, on-device or through a signed-in command-line tool.
actor NoteAssistant {
    private let commandLine = CommandLineAssistant()

    /// Which engines can actually run right now.
    func availableEngines() async -> [NoteAssistantEngine] {
        var engines: [NoteAssistantEngine] = []
        if SystemLanguageModel.default.isAvailable {
            engines.append(.onDevice)
        }
        for engine in [NoteAssistantEngine.claude, .codex]
        where await commandLine.locate(engine) != nil {
            engines.append(engine)
        }
        return engines
    }

    func run(
        _ action: NoteAction,
        on text: String,
        using engine: NoteAssistantEngine
    ) async throws -> String {
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { throw NoteAssistantError.emptyResult }

        let result: String
        switch engine {
        case .onDevice:
            result = try await runOnDevice(action, on: note)
        case .claude, .codex:
            result = try await commandLine.run(
                action,
                on: note,
                using: engine
            )
        }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NoteAssistantError.emptyResult }
        return trimmed
    }

    private func runOnDevice(
        _ action: NoteAction,
        on note: String
    ) async throws -> String {
        guard SystemLanguageModel.default.isAvailable else {
            throw NoteAssistantError.unavailable(.onDevice)
        }
        let session = LanguageModelSession(instructions: action.instruction)
        do {
            // The note is delimited and labelled as material, so a note that
            // happens to read as a request is worked on rather than answered.
            let response = try await session.respond(
                to: """
                Apply the instruction to the note between the markers.

                <<<NOTE
                \(note)
                NOTE>>>
                """
            )
            return response.content
        } catch {
            throw NoteAssistantError.failed(error.localizedDescription)
        }
    }
}
