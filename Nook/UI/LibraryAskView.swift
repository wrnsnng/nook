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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(
                    "Ask your library",
                    systemImage: "sparkle.magnifyingglass"
                )
                .font(.headline)
                Spacer()
                Button("Close") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 10) {
                TextField(
                    "What did we decide about…",
                    text: $question
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit(ask)
                .accessibilityLabel("Question about your notes")

                Button("Search", action: ask)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        question.trimmingCharacters(in: .whitespaces).isEmpty
                            || isAnswering || service.isPreparing
                    )
            }

            content
        }
        .padding(20)
        .frame(width: 560)
        .frame(minHeight: 380)
    }

    @ViewBuilder
    private var content: some View {
        if isAnswering || service.isPreparing {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Searching your notes on this Mac…")
                    .foregroundStyle(.secondary)
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
            Text(
                "Ask anything your meetings covered. Nook searches every note on this Mac and answers from what was actually said, citing the meetings it used."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if let error = service.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(NookPalette.danger)
        }
    }

    private func ask() {
        let currentQuestion = question.trimmingCharacters(in: .whitespaces)
        guard !currentQuestion.isEmpty else { return }
        answer = nil
        isAnswering = true
        Task {
            let result = await service.answer(
                question: currentQuestion,
                notes: notes
            )
            self.answer = result
            self.isAnswering = false
        }
    }
}
