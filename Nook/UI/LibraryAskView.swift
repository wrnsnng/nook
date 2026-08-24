import SwiftUI

/// Ask a question across the whole library, answered from the user's own
/// notes with citations back to the meetings they came from.
struct LibraryAskView: View {
    let notes: [MeetingNote]
    /// Called when the user taps a citation; the sheet closes first.
    let onSelectNote: (MeetingNote.ID) -> Void
    let onClose: () -> Void

    @StateObject private var service = LibraryAnswerService()
    @State private var question = ""
    @State private var answer: LibraryAnswer?
    @State private var isAnswering = false
    @State private var askTask: Task<Void, Never>?
    /// The question the answer in flight belongs to, so a wait of several
    /// seconds still says what is being looked up.
    @State private var askedQuestion: String?
    @FocusState private var questionFocused: Bool

    private var canAsk: Bool {
        !question.trimmingCharacters(in: .whitespaces).isEmpty
            && !isAnswering
            && !service.isPreparing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(
                "Ask your library",
                systemImage: "sparkle.magnifyingglass"
            )
            .font(NookType.panelTitle)

            TextField(
                "What did we decide about…",
                text: $question
            )
            .textFieldStyle(.roundedBorder)
            .focused($questionFocused)
            .onSubmit(ask)
            .accessibilityLabel("Question about your notes")

            content

            Spacer(minLength: 0)

            HStack(spacing: NookSpacing.medium) {
                Spacer()
                Button("Cancel") {
                    askTask?.cancel()
                    onClose()
                }
                .keyboardShortcut(.cancelAction)

                Button("Ask", action: ask)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAsk)
            }
        }
        .padding(20)
        .frame(width: 560)
        .frame(minHeight: 380, alignment: .top)
        // The field is the only thing to do here, so it starts with the
        // keyboard rather than asking for a click first.
        .onAppear { questionFocused = true }
    }

    /// Openers built from the user's own recent meetings, so the first thing
    /// a person sees is a question this library can actually answer.
    @ViewBuilder
    private var exampleQuestions: some View {
        let examples = LibraryAskExamples.questions(for: notes)
        if !examples.isEmpty {
            VStack(alignment: .leading, spacing: NookSpacing.xSmall + 2) {
                Text("Try one of these")
                    .font(NookType.micro.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(examples, id: \.self) { example in
                    AskExampleChip(question: example) {
                        question = example
                        questionFocused = true
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isAnswering || service.isPreparing {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Searching your notes on this Mac…")
                        .foregroundStyle(.secondary)
                }
                if let askedQuestion {
                    Text("“\(askedQuestion)”")
                        .font(NookType.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let answer {
            if let reason = answer.refusedReason {
                Label(reason, systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(answer.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if !answer.citations.isEmpty {
                            Divider()
                            Text("From your notes")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(answer.citations) { citation in
                                Button {
                                    onSelectNote(citation.chunk.noteID)
                                    onClose()
                                } label: {
                                    Label(
                                        citation.displayTitle,
                                        systemImage: "doc.text"
                                    )
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .help("Open this meeting")
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text(
                    "Ask anything your meetings covered. Nook searches every note on this Mac and answers from what was actually said, citing the meetings it used."
                )
                .font(NookType.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

                exampleQuestions
            }
        }

        if let error = service.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(NookPalette.danger)
        }
    }

    /// `.onSubmit` fires on every Return keypress regardless of the button's
    /// disabled state, so re-entry has to be guarded here rather than only
    /// at the button. A new question cancels whatever is still in flight
    /// instead of racing it, which would otherwise let a stale answer land
    /// after a newer one.
    private func ask() {
        guard !isAnswering, !service.isPreparing else { return }
        let currentQuestion = question.trimmingCharacters(in: .whitespaces)
        guard !currentQuestion.isEmpty else { return }

        askTask?.cancel()
        answer = nil
        askedQuestion = currentQuestion
        isAnswering = true
        askTask = Task {
            let result = await service.answer(
                question: currentQuestion,
                notes: notes
            )
            guard !Task.isCancelled else { return }
            self.answer = result
            self.isAnswering = false
        }
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
