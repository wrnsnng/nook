import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previewStep = 0
    @State private var previewTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            NookAmbientBackground()

            VStack(spacing: 0) {
                VStack(spacing: 11) {
                    NookPresence(state: .resting, size: 62)

                    VStack(spacing: 4) {
                        Text("Your meetings, kept close.")
                            .font(NookType.title)
                        Text(
                            "Nook catches the conversation, finds what matters, "
                                + "and saves a plain Markdown note on this Mac."
                        )
                        .font(NookType.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .frame(maxWidth: 430)
                    }
                }
                .padding(.top, 27)
                .padding(.bottom, 20)

                WelcomeTransformation(step: previewStep)
                    .padding(.horizontal, 34)

                HStack(spacing: 8) {
                    Image(systemName: "lock")
                        .foregroundStyle(NookPalette.accent)
                    Text("On-device transcription · Local summaries · Markdown files")
                }
                .font(NookType.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 13)
                .accessibilityElement(children: .combine)

                Toggle(
                    isOn: Binding(
                        get: { appModel.detector.isEnabled },
                        set: { appModel.detector.isEnabled = $0 }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notice likely meetings")
                            .font(NookType.control)
                        Text(
                            "Checks local window titles and app audio activity. "
                                + "Nook always asks before recording."
                        )
                        .font(NookType.micro)
                        .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 34)
                .padding(.top, 12)

                Spacer(minLength: 14)

                HStack(spacing: 14) {
                    Button(previewStep == 0 ? "See Nook work" : "Replay preview") {
                        runPreview()
                    }
                    .buttonStyle(.plain)
                    .font(NookType.control)
                    .foregroundStyle(NookPalette.accent)
                    .disabled(previewTask != nil)

                    Spacer()

                    Button("Open library") {
                        finishWelcome()
                        appModel.openLibrary()
                    }
                    .buttonStyle(.plain)
                    .font(NookType.control)

                    Button("Start with Nook") {
                        finishWelcome()
                        appModel.meeting.startManualMeeting()
                    }
                    .buttonStyle(
                        NookButtonStyle(
                            tint: NookPalette.accent,
                            isProminent: true
                        )
                    )
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 34)
                .padding(.bottom, 18)

                Link(
                    "A local-first Mac app by Common Tools Co.",
                    destination: URL(string: "https://www.common-tools.co/")!
                )
                .font(NookType.micro)
                .foregroundStyle(.secondary)
                .padding(.bottom, 14)
            }
        }
        .frame(width: 560, height: 480)
        .onDisappear {
            previewTask?.cancel()
            previewTask = nil
            appModel.completeWelcome()
        }
    }

    private func runPreview() {
        previewTask?.cancel()

        if reduceMotion {
            previewStep = 3
            return
        }

        previewTask = Task { @MainActor in
            withAnimation(NookMotion.quick) {
                previewStep = 0
            }
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }

            for step in 1...3 {
                withAnimation(step == 3 ? NookMotion.settle : NookMotion.spatial) {
                    previewStep = step
                }
                try? await Task.sleep(
                    for: step == 3 ? .milliseconds(760) : .milliseconds(880)
                )
                guard !Task.isCancelled else { return }
            }
            previewTask = nil
        }
    }

    private func finishWelcome() {
        previewTask?.cancel()
        appModel.completeWelcome()
        dismissWindow(id: "welcome")
    }
}

private struct WelcomeTransformation: View {
    let step: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 17) {
            VStack(alignment: .leading, spacing: 7) {
                Label("Spoken", systemImage: "quote.bubble")
                    .font(NookType.metadata)
                    .foregroundStyle(.secondary)
                Text("“Let’s send the revised brief on Friday.”")
                    .font(NookType.bodyEmphasized)
                    .lineSpacing(2)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            NookPresence(
                state: presenceState,
                size: 46,
                showsSurface: false
            )
            .frame(width: 48)

            VStack(alignment: .leading, spacing: 7) {
                Label(
                    step >= 3 ? "Saved locally" : "Useful note",
                    systemImage: step >= 3 ? "doc.badge.checkmark" : "text.alignleft"
                )
                .font(NookType.metadata)
                .foregroundStyle(step >= 3 ? NookPalette.accent : .secondary)

                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "circle")
                        .font(.system(size: 5, weight: .bold))
                        .foregroundStyle(NookPalette.accent)
                    Text("Send revised brief · Friday")
                        .font(NookType.bodyEmphasized)
                        .foregroundStyle(step >= 2 ? .primary : .tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 19)
        .frame(height: 126)
        .background(
            NookPalette.paper,
            in: RoundedRectangle(
                cornerRadius: NookRadius.surface,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: NookRadius.surface,
                style: .continuous
            )
            .stroke(
                .primary.opacity(colorScheme == .dark ? 0.12 : 0.08),
                lineWidth: 0.7
            )
        }
        .shadow(
            color: .black.opacity(colorScheme == .dark ? 0.16 : 0.055),
            radius: 18,
            y: 7
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            step >= 3
                ? "Nook turns the spoken sentence into an action and saves it locally."
                : "Preview: spoken words become a useful meeting note."
        )
    }

    private var presenceState: NookPresenceState {
        switch step {
        case 0: .resting
        case 1: .listening(level: 0.56, isPaused: false)
        case 2: .thinking
        default: .saved
        }
    }
}
