import SwiftUI

struct FloatingNotesView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var meeting: MeetingCoordinator
    /// One focus request when the window opens. A polled focus state used
    /// to sit here, and during a meeting this window re-renders with every
    /// meter tick, which kept blurring the field it had just focused.
    @State private var focusToken = 0

    var body: some View {
        ZStack {
            NookAmbientBackground()

            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                    .padding(.bottom, 14)

                SoftDivider()

                LiveNotesEditor(focusToken: focusToken)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(NookWindowBridge(role: .liveNotes, floats: true))
        .onAppear {
            guard meeting.phase.isRecording else {
                dismiss()
                return
            }
            focusToken += 1
        }
        .onChange(of: meeting.phase) { _, phase in
            guard !phase.isRecording else { return }
            dismiss()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("My notes")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: meeting.isPaused ? "pause.fill" : "pencil.line")
                .font(NookType.metadata)
                .foregroundStyle(
                    meeting.isPaused
                        ? NookPalette.warning
                        : NookPalette.accent
                )
                .frame(width: 24, height: 24)
                .background(
                    .primary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text("My notes")
                    .font(NookType.panelTitle)
                Text(statusLabel)
                    .font(NookType.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(elapsedLabel)
                .font(NookType.code)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
    }

    private var statusLabel: String {
        switch meeting.phase {
        case .recording:
            meeting.isPaused
                ? "Paused · included when this meeting ends"
                : "Included in the note when this meeting ends"
        case .processing:
            "Finishing your meeting note"
        case .completed:
            "Saved in the Nook library"
        default:
            "Start a meeting to attach these notes"
        }
    }

    private var elapsedLabel: String {
        NookElapsedTime.clock(meeting.elapsed)
    }
}

/// The live-notes editor alone, binding straight to `meeting.liveNotes`.
///
/// `FloatingNotesView` itself still needs the coordinator for its header's
/// elapsed clock, so it cannot avoid observing `MeetingCoordinator`
/// altogether; pulling the editor out here at least keeps it from being
/// entangled with the header and the window bridge in one body, and matches
/// `NookNotesEditor`'s own fix (see its `updateNSView`) that already makes an
/// audio-level or elapsed tick a no-op for the text view underneath this.
private struct LiveNotesEditor: View {
    @EnvironmentObject private var meeting: MeetingCoordinator
    let focusToken: Int

    var body: some View {
        NookNotesEditor(
            text: $meeting.liveNotes,
            placeholder: "Capture a thought, question, or follow-up…",
            focusToken: focusToken,
            contentInsets: EdgeInsets(
                top: 20,
                leading: 23,
                bottom: 20,
                trailing: 23
            ),
            lineSpacing: 5
        )
    }
}
