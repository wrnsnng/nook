import SwiftUI

/// Review is deliberately a separate, keyboard-accessible decision. Return
/// keeps the literal words; applying a destructive interpretation is explicit.
struct VoiceCorrectionView: View {
    @ObservedObject var note: QuickNoteController
    let proposal: VoiceCorrectionProposal
    @Environment(\.dismiss) private var dismiss
    @State private var replacement: String

    init(note: QuickNoteController, proposal: VoiceCorrectionProposal) {
        self.note = note
        self.proposal = proposal
        _replacement = State(initialValue: proposal.replacement)
    }

    private var isCurrent: Bool { note.isCurrentVoiceCorrection(proposal) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(proposal.isRemoval ? "Remove the previous dictated phrase?" : "Change the previous list item?")
                .font(.headline)
            Text("Dictation is paused. Nothing changes until you apply this correction. Keeping the words leaves your original speech in the note.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if note.outboundEngine != nil {
                Label(note.outboundMessage, systemImage: "arrow.up.forward.app.fill")
                    .font(.caption)
            }
            Text("You said").font(.subheadline.weight(.semibold))
            sourceText(proposal.utterance, label: "Recognized correction words")
            Text("Original words").font(.subheadline.weight(.semibold))
            sourceText(proposal.originalWords, label: "Words affected by correction")
            if !proposal.isRemoval {
                Text("Replacement words").font(.subheadline.weight(.semibold))
                NookNotesEditor(text: $replacement, placeholder: "Type the replacement words.",
                                accessibilityLabel: "Replacement words")
                    .frame(height: 110)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .disabled(!isCurrent)
                Text("The existing list marker and checkbox state stay unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !isCurrent {
                Text("The note changed. This correction can no longer be applied; your current words are kept.")
                    .font(.callout)
            } else if let status = note.voiceStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Keep Words") {
                    note.keepVoiceWords(proposal)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Cancel correction and keep dictated words")
                Spacer()
                Button("Apply Correction") {
                    if note.applyVoiceCorrection(proposal, replacement: replacement) { dismiss() }
                }
                .disabled(!isCurrent || proposal.correctedText(replacement: replacement) == nil)
                .help("Apply exactly this reviewed edit. Undo restores the original words.")
            }
        }
        .padding(24)
        .frame(width: 480)
        .onExitCommand {
            note.keepVoiceWords(proposal)
            dismiss()
        }
    }

    private func sourceText(_ text: String, label: String) -> some View {
        ScrollView {
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 62)
        .accessibilityLabel(label)
    }
}
