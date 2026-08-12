import SwiftUI

/// The floating window a spoken note lands in.
struct QuickNoteView: View {
    @EnvironmentObject private var note: QuickNoteController

    var body: some View {
        VStack(spacing: 0) {
            editor
            actionBar
        }
        .background(NookPalette.paper)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $note.text)
                .font(NookType.transcript)
                .lineSpacing(2)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, NookSpacing.large)
                .padding(.top, NookSpacing.medium)
                .accessibilityLabel("Spoken note")

            if note.text.isEmpty {
                Text("Hold your dictation shortcut and start talking.")
                    .font(NookType.transcript)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, NookSpacing.large + 5)
                    .padding(.top, NookSpacing.medium + 8)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: NookSpacing.small) {
            if let provider = note.engine.provider {
                outboundBanner(provider: provider)
            }

            if let message = note.message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(NookType.caption)
                    .foregroundStyle(NookPalette.warning)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }

            HStack(spacing: NookSpacing.xSmall) {
                ForEach(NoteAction.allCases) { action in
                    NoteActionButton(
                        action: action,
                        isRunning: note.runningAction == action,
                        isEnabled: canAct,
                        help: helpText(for: action)
                    ) {
                        note.run(action)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: NookSpacing.small) {
                engineControl
                Spacer(minLength: NookSpacing.small)
                status
                Button("Open in Library") {
                    note.saveAndOpenInLibrary()
                }
                .controlSize(.small)
                .disabled(note.text.isEmpty)
            }
        }
        .padding(.horizontal, NookSpacing.large)
        .padding(.vertical, NookSpacing.medium)
        .background {
            // A distinct surface rather than a hairline, so the bar reads as a
            // place for controls instead of a stray row under the text.
            Rectangle()
                .fill(.quaternary.opacity(0.4))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(.separator)
                        .frame(height: NookSpacing.hairline)
                }
        }
        .animation(.easeOut(duration: 0.15), value: note.message)
        .animation(.easeOut(duration: 0.15), value: note.engine)
    }

    /// States plainly, and permanently, that actions will send this note away.
    ///
    /// The engine is remembered between notes, so the choice can easily have
    /// been made days ago. A marker that only appears on hover would leave a
    /// user believing Nook's usual promise still holds while it no longer does.
    private func outboundBanner(provider: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NookSpacing.small) {
            Image(systemName: "arrow.up.forward.app.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NookPalette.warning)
                .accessibilityHidden(true)

            Text("Running an action sends this note to \(provider).")
                .font(NookType.micro)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button("Keep on this Mac") {
                note.selectEngine(.onDevice)
            }
            .buttonStyle(.link)
            .font(NookType.micro.weight(.medium))
        }
        .padding(.horizontal, NookSpacing.small + 2)
        .padding(.vertical, NookSpacing.xSmall + 2)
        .background {
            RoundedRectangle(cornerRadius: NookRadius.control, style: .continuous)
                .fill(NookPalette.warning.opacity(0.12))
                .overlay {
                    RoundedRectangle(
                        cornerRadius: NookRadius.control,
                        style: .continuous
                    )
                    .strokeBorder(
                        NookPalette.warning.opacity(0.3),
                        lineWidth: NookSpacing.hairline
                    )
                }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Warning. Running an action sends this note to \(provider)."
        )
    }

    /// One control for the engine, carrying its own privacy marker.
    ///
    /// The picker and a separate "On this Mac" label previously said the same
    /// thing twice, side by side. Where the work happens and whether it leaves
    /// the Mac are the same fact, so they belong to one control.
    @ViewBuilder
    private var engineControl: some View {
        if note.availableEngines.isEmpty {
            Label("No assistant available", systemImage: "sparkles.slash")
                .font(NookType.micro)
                .foregroundStyle(.secondary)
        } else {
            Menu {
                ForEach(note.availableEngines) { engine in
                    Button {
                        note.selectEngine(engine)
                    } label: {
                        // The provider is named in the menu itself, so the
                        // consequence is legible before the choice is made
                        // rather than only after it.
                        if let provider = engine.provider {
                            Label(
                                "\(engine.title), sends to \(provider)",
                                systemImage: symbol(for: engine)
                            )
                        } else {
                            Label(engine.title, systemImage: symbol(for: engine))
                        }
                    }
                }
            } label: {
                Label {
                    Text(note.engine.title)
                        .font(NookType.micro.weight(.medium))
                } icon: {
                    Image(systemName: symbol(for: note.engine))
                        .foregroundStyle(
                            note.engine.leavesTheMac
                                ? NookPalette.warning
                                : NookPalette.success
                        )
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(note.engine.detail)
            .disabled(note.availableEngines.count < 2)
        }
    }

    private var status: some View {
        Text(statusText)
            .font(NookType.micro)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
            .animation(.default, value: statusText)
    }

    private var statusText: String {
        guard note.wordCount > 0 else { return "" }
        let words = "\(note.wordCount) word\(note.wordCount == 1 ? "" : "s")"
        return note.lastSavedAt == nil ? words : "\(words) · Saved"
    }

    private var canAct: Bool {
        !note.text.isEmpty && !note.isWorking && !note.availableEngines.isEmpty
    }

    private func symbol(for engine: NoteAssistantEngine) -> String {
        engine.leavesTheMac ? "arrow.up.forward.app.fill" : "lock.fill"
    }

    private func helpText(for action: NoteAction) -> String {
        guard !note.availableEngines.isEmpty else {
            return "No assistant is available on this Mac."
        }
        return action.replacesNote
            ? "\(action.title). Rewrites the note using \(note.engine.title)."
            : "\(action.title). Adds a section using \(note.engine.title)."
    }
}

/// One note action, styled as a quiet chip that lights up under the pointer.
private struct NoteActionButton: View {
    let action: NoteAction
    let isRunning: Bool
    let isEnabled: Bool
    let help: String
    let perform: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: perform) {
            HStack(spacing: NookSpacing.xSmall + 1) {
                Group {
                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.55)
                    } else {
                        Image(systemName: action.symbol)
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .frame(width: 13, height: 13)

                Text(action.title)
                    .font(NookType.micro.weight(.medium))
            }
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .padding(.horizontal, NookSpacing.small + 2)
            .padding(.vertical, NookSpacing.xSmall + 2)
            .background {
                RoundedRectangle(cornerRadius: NookRadius.control, style: .continuous)
                    .fill(fill)
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: NookRadius.control,
                            style: .continuous
                        )
                        .strokeBorder(
                            NookPalette.accent.opacity(isHovering && isEnabled ? 0.35 : 0),
                            lineWidth: NookSpacing.hairline
                        )
                    }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isRunning)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.12), value: isRunning)
        .help(help)
        .accessibilityLabel(action.title)
        .accessibilityHint(help)
    }

    private var fill: Color {
        guard isEnabled else { return .clear }
        if isRunning { return NookPalette.accent.opacity(0.16) }
        return isHovering
            ? NookPalette.accent.opacity(0.12)
            : Color.primary.opacity(0.05)
    }
}
