import SwiftUI

/// The selected item owns this sheet. Source inspection never saves anything;
/// correction and removal require a separate reviewed Apply action.
struct SummaryItemReviewView: View {
    @ObservedObject var session: SummaryItemReviewSession
    @EnvironmentObject private var store: MarkdownStore
    @EnvironmentObject private var markdownDraft: MarkdownDraftController
    @EnvironmentObject private var personalNotes: PersonalNotesDraftController
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPassageID: String?
    @State private var feedback = ""
    @FocusState private var focused: String?
    @AccessibilityFocusState private var accessibleFocus: String?

    init(session: SummaryItemReviewSession, initialPassageID: String? = nil, initialFeedback: String = "") {
        self.session = session
        _selectedPassageID = State(initialValue: initialPassageID)
        _feedback = State(initialValue: initialFeedback)
    }

    private var current: MeetingNote? { store.uniqueNote(id: session.original.id) }
    private var isCurrent: Bool {
        session.isCurrent(note: current, generation: store.storageGeneration)
            && !markdownDraft.hasChanges && !personalNotes.hasExactChanges
            && !store.summarySessions.session(for: session.original).isRunning
    }
    private var selectedPassage: SummaryEvidencePassage? {
        session.passages.first { $0.id == selectedPassageID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review \(session.item.kind.label.lowercased())").font(.title2)
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(session.item.text).textSelection(.enabled)
                        Text("Related transcript passages may support or contradict this item. Similarity is not proof. Review the words before applying a correction.")
                            .font(.callout).foregroundStyle(.secondary)
                        if session.isLoading {
                            ProgressView("Finding related transcript passages…")
                        } else if session.passages.isEmpty {
                            Text("No related passage was found. This does not establish that the item is supported. You can keep it or review its removal.")
                        }
                        ForEach(session.passages) { passage in
                            VStack(alignment: .leading, spacing: 8) {
                                Button {
                                    selectedPassageID = passage.id
                                } label: {
                                    Label(passage.label, systemImage: selectedPassageID == passage.id
                                          ? "checkmark.circle.fill" : "circle")
                                }
                                .accessibilityLabel("Use transcript at \(passage.label) for correction")
                                .accessibilityValue(selectedPassageID == passage.id ? "Selected" : "Not selected")
                                .disabled(!isCurrent || session.saved != nil)
                                .focused($focused, equals: passage.id)
                                .accessibilityFocused($accessibleFocus, equals: passage.id)
                                Text(passage.text).textSelection(.enabled)
                            }
                            .id(passage.id)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityElement(children: .contain)
                        }
                        if session.saved == nil {
                            correctionControls
                        }
                        if let proposal = session.proposal {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Proposed replacement").font(.headline)
                                Text(proposal.replacement).textSelection(.enabled)
                                Text("Selected supporting quote").font(.subheadline)
                                Text(proposal.quote).textSelection(.enabled)
                                Text("Check this proposal yourself. Applying replaces only this item. Existing action due dates and completion stay unchanged.")
                                    .font(.caption)
                            }
                            .id("proposal")
                        } else if session.previewsRemoval {
                            Text("Apply Removal deletes only the item shown above. It does not delete transcript words, other items or My notes. Undo is available here until you close this review.")
                                .id("proposal")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 220, idealHeight: 420, maxHeight: 500)
                .onChange(of: session.proposal != nil || session.previewsRemoval) { _, hasPreview in
                    if hasPreview { reader.scrollTo("proposal", anchor: .bottom) }
                }
            }
            if !isCurrent {
                Text("The note, draft or library changed, or a summary is running. Close this review and reopen it after saving your changes.")
                    .font(.callout)
            }
            if let message = session.message {
                Text(message).font(.callout).textSelection(.enabled)
                    .accessibilityFocused($accessibleFocus, equals: "status")
            }
            HStack {
                Button("Back to Item") { session.cancel(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                Spacer()
                if session.saved != nil {
                    Button("Undo Correction") {
                        session.undo(current: current, generation: store.storageGeneration, commit: commit)
                    }
                    .disabled(!isCurrent || session.didUndo)
                } else if session.proposal != nil || session.previewsRemoval {
                    Button(session.previewsRemoval ? "Apply Removal" : "Apply Correction") {
                        session.apply(current: current, generation: store.storageGeneration, commit: commit)
                    }
                    .disabled(!isCurrent || session.isGenerating)
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .onExitCommand { session.cancel(); dismiss() }
        .onDisappear { session.cancel() }
        .task { session.load(); await session.waitForWork() }
        .onChange(of: selectedPassageID) { _, _ in session.invalidateProposal() }
        .onChange(of: feedback) { _, _ in session.invalidateProposal() }
        .onChange(of: isCurrent) { _, valid in if !valid { session.invalidateProposal() } }
        .onChange(of: session.passages) { _, passages in
            if let first = passages.first {
                focused = first.id
                accessibleFocus = first.id
            }
        }
        .onChange(of: session.message) { _, message in
            if message != nil { accessibleFocus = "status" }
        }
    }

    private var correctionControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("What should be corrected?", text: $feedback, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .disabled(!isCurrent)
            Text("Feedback is used for this correction only. It is not a lasting instruction for future summaries.")
                .font(.caption).foregroundStyle(.secondary)
            if feedback.count > 1_000 {
                Text("Shorten your feedback to 1,000 characters before requesting a correction.")
                    .font(.caption)
            }
            HStack {
                Button("Correct This") { session.propose(passage: selectedPassage, feedback: feedback) }
                    .disabled(!isCurrent || selectedPassage == nil || session.isGenerating || session.isLoading || feedback.count > 1_000)
                Button("Not Supported…") { session.previewRemoval() }
                    .disabled(!isCurrent || session.isGenerating || session.isLoading)
                if session.isGenerating {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { session.invalidateProposal() }
                }
            }
        }
    }

    private func commit(_ updated: MeetingNote) throws -> MeetingNote {
        guard isCurrent else { throw SummaryReviewError.changed }
        let saved = try store.save(updated)
        markdownDraft.refresh(for: saved, store: store)
        personalNotes.refresh(for: saved)
        return saved
    }
}
