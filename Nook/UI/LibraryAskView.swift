import SwiftUI

/// In-place native presentation retains its root view instead of rebuilding it
/// with the library. Keep new questions and example chips on the current notes,
/// without replacing the session or its draft during an ordinary reload.
struct LibraryAskStoreHost: View {
    @ObservedObject var store: MarkdownStore
    let session: LibraryAskSession
    let onSelectNote: (MeetingNote.ID) -> Void
    let onClose: () -> Void

    var body: some View {
        LibraryAskView(
            notes: store.notes, onSelectNote: onSelectNote,
            onClose: onClose, session: session
        )
    }
}

/// Ask a question across the whole library, answered from the user's own
/// notes with citations back to the meetings they came from.
struct LibraryAskView: View {
    let notes: [MeetingNote]
    /// Called when the user taps a citation; the sheet closes first.
    let onSelectNote: (MeetingNote.ID) -> Void
    let onClose: () -> Void

    @StateObject private var session: LibraryAskSession
    @FocusState private var questionFocused: Bool

    init(
        notes: [MeetingNote],
        onSelectNote: @escaping (MeetingNote.ID) -> Void,
        onClose: @escaping () -> Void,
        session: LibraryAskSession? = nil
    ) {
        self.notes = notes
        self.onSelectNote = onSelectNote
        self.onClose = onClose
        _session = StateObject(wrappedValue: session ?? LibraryAskSession())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(
                "Ask your library",
                systemImage: "sparkle.magnifyingglass"
            )
            .font(NookType.panelTitle)
            .accessibilityAddTraits(.isHeader)

            TextField(
                "What did we decide about…",
                text: $session.question
            )
            .textFieldStyle(.roundedBorder)
            .focused($questionFocused)
            .onSubmit(ask)
            .accessibilityLabel("Question about your notes")

            content

            if !LibraryNoteAggregation.partition(notes).omitted.isEmpty {
                Label(LibraryNoteAggregation.omissionMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack(spacing: NookSpacing.medium) {
                Spacer()
                Button("Cancel") {
                    session.cancel()
                    onClose()
                }
                .keyboardShortcut(.cancelAction)

                Button("Ask", action: ask)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!session.canAsk)
            }
        }
        .padding(20)
        .frame(width: 560)
        .frame(minHeight: 380, alignment: .top)
        // Register initial focus while the native host prepares its key loop,
        // including when Ask replaces an already attached palette sheet.
        .defaultFocus($questionFocused, true)
        // A sheet can disappear through its parent, not only its Cancel button.
        // Invalidate the response before cancellation reaches asynchronous work.
        .onDisappear { session.cancel() }
    }

    /// Openers built from the user's own recent meetings, so the first thing
    /// a person sees is a question this library can actually answer.
    @ViewBuilder
    private var exampleQuestions: some View {
        let examples = LibraryAskExamples.questions(
            for: LibraryNoteAggregation.partition(notes).eligible
        )
        if !examples.isEmpty {
            VStack(alignment: .leading, spacing: NookSpacing.xSmall + 2) {
                Text("Try one of these")
                    .font(NookType.label)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(examples, id: \.self) { example in
                    AskExampleChip(question: example) {
                        session.question = example
                        questionFocused = true
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if session.isAnswering {
            VStack(alignment: .leading, spacing: 14) {
                // Keep the status and footer reachable even when the submitted
                // question is much taller than the sheet. Scrolling preserves
                // the full question rather than truncating its visible text.
                ScrollView {
                    submittedQuestion
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .fixedSize(horizontal: false, vertical: true)

                // Held in the place the answer will appear, so the sheet does
                // not rearrange itself when the answer arrives.
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Searching your notes on this Mac")
                    Text("Searching your notes on this Mac\u{2026}")
                        .font(NookType.transcript)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(AskAnswerSurface(fill: NookPalette.leadSurface))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let answer = session.answer {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    submittedQuestion

                    if let reason = answer.refusedReason {
                        // Not an error: Nook declining to guess is the
                        // feature working. It sits where an answer would, in
                        // a neutral wash rather than the answer's tint.
                        Label {
                            Text(reason)
                                .font(NookType.transcript)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "questionmark.circle")
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .modifier(AskAnswerSurface(fill: Color.primary.opacity(0.045)))
                    } else {
                        // The answer is the lead of this sheet, set apart as
                        // a note's "In summary" is: a soft tint, no border.
                        Text(answer.text)
                            .font(NookType.transcript)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .modifier(AskAnswerSurface(fill: NookPalette.leadSurface))

                        if !answer.citations.isEmpty {
                            citations(answer.citations)
                                .padding(.top, 8)
                        }
                    }

                    if let error = session.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(NookPalette.danger)
                    }
                }
                .padding(.bottom, 8)
            }
        } else {
            VStack(alignment: .leading, spacing: 18) {
                Text(
                    "Ask anything your meetings covered. Nook searches your notes on this Mac and answers from what was actually said, citing the meetings it used."
                )
                .font(NookType.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

                exampleQuestions
            }
        }
    }

    /// The meetings an answer drew on, as rows that open them: the
    /// document glyph, the title, when it happened, and a chevron.
    private func citations(_ citations: [LibraryCitation]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("From your notes")
                .font(NookType.label)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(citations.enumerated()), id: \.element.id) { index, citation in
                    Button {
                        onSelectNote(citation.chunk.noteID)
                        onClose()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text")
                                .font(NookType.transcript)
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(citation.chunk.noteTitle)
                                    .font(NookType.transcript)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(
                                    citation.chunk.startedAt.formatted(
                                        date: .abbreviated, time: .omitted
                                    )
                                )
                                .font(NookType.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(NookType.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(NookLinkRowButtonStyle(bleed: 8))
                    .help("Open this meeting")
                    .accessibilityLabel(citation.displayTitle)
                    .accessibilityHint("Opens this meeting and closes Ask")

                    if index < citations.count - 1 {
                        Divider().padding(.leading, 30)
                    }
                }
            }
        }
    }

    /// The question heads its answer, as a note's title heads its page.
    @ViewBuilder
    private var submittedQuestion: some View {
        if let question = session.submittedQuestion {
            Text(question)
                .font(NookType.sectionTitle)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Your question: \(question)")
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func ask() {
        session.ask(notes: notes)
    }
}

/// Keeps the submitted question and its outcome together while the field remains
/// an editable draft. Work may finish after a sheet closes, so neither service
/// flags nor cancellation alone decide which response is allowed to appear.
@MainActor
final class LibraryAskSession: ObservableObject {
    struct Response: Sendable {
        let answer: LibraryAnswer
        var errorMessage: String? = nil
    }

    typealias Answerer = @MainActor @Sendable (String, [MeetingNote]) async -> Response

    private enum Phase {
        case ready
        case searching(question: String)
        case answered(question: String, response: Response)
    }

    @Published var question = ""
    @Published private var phase: Phase = .ready
    private let answerer: Answerer
    private var requestID: UUID?
    private var askTask: Task<Void, Never>?

    init(answerer: Answerer? = nil) {
        self.answerer = answerer ?? { question, notes in
            // A request owns its service status and error. A canceled service
            // can finish late without changing the state of a later question.
            // The existing on-disk retrieval cache is still shared by location.
            let service = LibraryAnswerService()
            let answer = await service.answer(question: question, notes: notes)
            return Response(answer: answer, errorMessage: service.lastError)
        }
    }

    deinit {
        askTask?.cancel()
    }

    var canAsk: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isAnswering
    }

    var isAnswering: Bool {
        if case .searching = phase { return true }
        return false
    }

    var submittedQuestion: String? {
        switch phase {
        case .ready: nil
        case .searching(let question), .answered(let question, _): question
        }
    }

    var answer: LibraryAnswer? {
        guard case .answered(_, let response) = phase else { return nil }
        return response.answer
    }

    var errorMessage: String? {
        guard case .answered(_, let response) = phase else { return nil }
        return response.errorMessage
    }

    /// Return can fire even while the Ask button is disabled. Refuse re-entry
    /// here, preserving any next question the user has already begun drafting.
    @discardableResult
    func ask(notes: [MeetingNote]) -> Task<Void, Never>? {
        guard canAsk else { return nil }
        let submitted = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID()
        requestID = id
        phase = .searching(question: submitted)
        let answerer = answerer
        let task = Task { [weak self] in
            guard !Task.isCancelled, self?.requestID == id else { return }
            let response = await answerer(submitted, notes)
            guard !Task.isCancelled, self?.requestID == id else { return }
            self?.phase = .answered(question: submitted, response: response)
            self?.askTask = nil
        }
        askTask = task
        return task
    }

    func cancel() {
        requestID = nil
        askTask?.cancel()
        askTask = nil
        if isAnswering {
            phase = .ready
        }
    }
}

/// The surface an answer, a refusal or the search in progress sits on:
/// the note page's lead tint, with the same generous inset.
private struct AskAnswerSurface: ViewModifier {
    let fill: Color

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: NookRadius.surface, style: .continuous)
                    .fill(fill)
            )
    }
}

/// One suggested opener. A button rather than a label, with the hover and
/// focus treatment every other control here has, so keyboard users can see
/// which chip Return will take.
private struct AskExampleChip: View {
    let question: String
    let onPick: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onPick) {
            Text(question)
                .font(NookType.caption)
                .foregroundStyle(Color(nsColor: .labelColor))
                .lineLimit(1)
                .padding(.horizontal, 11)
                .frame(minHeight: 28)
                .background(
                    Capsule().fill(
                        NookPalette.accent.opacity(isHovering ? 0.18 : 0.10)
                    )
                )
                .contentShape(Capsule())
                .nookFocusRing(Capsule(), isVisible: isFocused)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onHover { isHovering = $0 }
        .animation(NookMotion.quick, value: isHovering)
        .help("Put this question in the field")
        .accessibilityHint("Fills the question field with this example")
    }
}

/// Openers derived from the library itself.
///
/// Deterministic on purpose: the suggestions are assembled from note titles
/// rather than generated, so they cannot invent a meeting the user never had.
enum LibraryAskExamples {
    /// Templates applied to the most recent meetings, newest first.
    private static let templates = [
        "What did we decide about \u{201C}%@\u{201D}?",
        "What is still open from \u{201C}%@\u{201D}?",
        "What did we say about \u{201C}%@\u{201D}?",
    ]

    static func questions(
        for notes: [MeetingNote],
        limit: Int = 3
    ) -> [String] {
        var seenTitles: Set<String> = []
        let titles = notes
            .filter { $0.kind != .digest }
            .sorted { $0.startedAt > $1.startedAt }
            .map(\.title)
            .filter { title in
                let trimmed = title.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !trimmed.isEmpty else { return false }
                return seenTitles.insert(trimmed.localizedLowercase).inserted
            }
            .prefix(min(limit, templates.count))

        return titles.enumerated().map { index, title in
            String(
                format: templates[index],
                title.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
