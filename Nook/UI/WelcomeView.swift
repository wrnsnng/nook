import AppKit
import SwiftUI

enum WelcomeStep: Int, CaseIterable {
    case introduction
    case microphone
    case speechRecognition
    case screenRecording
    case ready

    var permission: NookPermission? {
        switch self {
        case .screenRecording:
            .screenRecording
        case .microphone:
            .microphone
        case .speechRecognition:
            .speechRecognition
        case .introduction, .ready:
            nil
        }
    }
}

struct WelcomeView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var detector: MeetingDetector
    @StateObject private var permissions = PermissionSetupController()
    @State private var step = WelcomeStep.introduction
    @State private var previewStep = 0
    @State private var previewTask: Task<Void, Never>?
    private let completeWelcomeAction: @MainActor () -> Void
    private let openLibraryAction: @MainActor () -> Void

    init(
        appModel: AppModel,
        initialStep: WelcomeStep = .introduction
    ) {
        _detector = ObservedObject(wrappedValue: appModel.detector)
        _step = State(initialValue: initialStep)
        completeWelcomeAction = { appModel.completeWelcome() }
        openLibraryAction = { appModel.openLibrary() }
    }

    init(
        detector: MeetingDetector,
        initialStep: WelcomeStep = .introduction
    ) {
        _detector = ObservedObject(wrappedValue: detector)
        _step = State(initialValue: initialStep)
        completeWelcomeAction = {}
        openLibraryAction = {}
    }

    var body: some View {
        ZStack {
            NookAmbientBackground()

            VStack(spacing: 0) {
                setupHeader

                Group {
                    switch step {
                    case .introduction:
                        introduction
                    case .screenRecording, .microphone, .speechRecognition:
                        if let permission = step.permission {
                            permissionSetup(permission)
                        }
                    case .ready:
                        ready
                    }
                }
                .id(step)
                .transition(.opacity.combined(with: .move(edge: .trailing)))

                setupFooter
            }
        }
        .frame(
            minWidth: 620,
            idealWidth: 680,
            maxWidth: .infinity,
            minHeight: 520,
            idealHeight: 560,
            maxHeight: .infinity
        )
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            permissions.refreshAfterBecomingActive()
        }
        .onDisappear {
            previewTask?.cancel()
            previewTask = nil
        }
    }

    private var setupHeader: some View {
        HStack(spacing: 9) {
            NookMark(size: 28)
                .accessibilityHidden(true)
            Text("Nook")
                .font(NookType.control)

            Spacer()

            Text("Step \(step.rawValue + 1) of \(WelcomeStep.allCases.count)")
                .font(NookType.metadata)
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    "Setup step \(step.rawValue + 1) of \(WelcomeStep.allCases.count)"
                )

            Button(step == .ready ? "Close" : "Skip setup") {
                finishWelcome()
            }
            .buttonStyle(.plain)
            .font(NookType.metadata)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .frame(height: 54)
        .overlay(alignment: .bottom) {
            SoftDivider()
        }
    }

    private var introduction: some View {
        VStack(spacing: 0) {
            VStack(spacing: 9) {
                NookPresence(state: .resting, size: 58)

                Text("Your meetings, kept close.")
                    .font(NookType.title)
                    .accessibilityAddTraits(.isHeader)

                Text(
                    "Nook catches the conversation, finds what matters, "
                        + "and saves a plain Markdown note on this Mac."
                )
                .font(NookType.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 450)
            }
            .padding(.top, 22)
            .padding(.bottom, 18)

            WelcomeTransformation(step: previewStep)
                .padding(.horizontal, 50)

            HStack(spacing: 8) {
                Image(systemName: "lock")
                    .foregroundStyle(NookPalette.accent)
                Text("On-device transcription · Local summaries · Markdown files")
            }
            .font(NookType.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 16)
            .accessibilityElement(children: .combine)

            Button(previewStep == 0 ? "See Nook work" : "Replay preview") {
                runPreview()
            }
            .buttonStyle(.plain)
            .font(NookType.control)
            .foregroundStyle(NookPalette.accent)
            .padding(.top, 15)
            .disabled(previewTask != nil)

            Spacer()
        }
    }

    private func permissionSetup(_ permission: NookPermission) -> some View {
        let status = permissions.status(for: permission)

        return VStack(spacing: 0) {
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(NookPalette.accent.opacity(0.11))
                        .frame(width: 74, height: 74)
                    Image(systemName: permission.symbol)
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(NookPalette.accent)
                }
                .accessibilityHidden(true)

                Text(permission.title)
                    .font(NookType.title)
                    .accessibilityAddTraits(.isHeader)

                Text(permission.setupDescription)
                    .font(NookType.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 440)
            }
            .padding(.top, 31)

            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(NookPalette.accent)
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Why Nook asks")
                            .font(NookType.bodyEmphasized)
                        Text(permission.privacyExplanation)
                            .font(NookType.caption)
                            .foregroundStyle(.secondary)
                            .lineSpacing(2)
                    }
                }

                SoftDivider()

                HStack(spacing: 9) {
                    Image(systemName: status.symbol)
                        .foregroundStyle(statusTint(status))
                    Text(status.label)
                        .font(NookType.bodyEmphasized)
                    Spacer()
                    Text("macOS controls this permission")
                        .font(NookType.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(permission.title): \(status.label)")
            }
            .padding(18)
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
                .stroke(.primary.opacity(0.09), lineWidth: 0.7)
            }
            .padding(.horizontal, 68)
            .padding(.top, 28)

            if permission == .screenRecording {
                Text(
                    status == .allowed
                        ? "Both macOS access checks are complete. No test recording was created."
                        : "You may see two macOS alerts. Nook only checks access here—nothing is recorded or saved."
                )
                    .font(NookType.micro)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 88)
                    .padding(.top, 11)
            }

            Spacer()
        }
    }

    private var ready: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                NookPresence(
                    state: permissions.allPermissionsAllowed ? .saved : .resting,
                    size: 64
                )

                Text(
                    permissions.allPermissionsAllowed
                        ? "Nook is ready."
                        : "You’re ready to explore."
                )
                .font(NookType.title)
                .accessibilityAddTraits(.isHeader)

                Text(
                    permissions.allPermissionsAllowed
                        ? "Start a recording whenever a meeting begins. Nook will keep the note local."
                        : "You can finish any missing permissions now or when you start your first recording."
                )
                .font(NookType.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 470)
            }
            .padding(.top, 27)

            VStack(spacing: 0) {
                ForEach(NookPermission.allCases) { permission in
                    let status = permissions.status(for: permission)
                    HStack(spacing: 11) {
                        Image(systemName: permission.symbol)
                            .foregroundStyle(NookPalette.accent)
                            .frame(width: 20)
                        Text(permission.title)
                            .font(NookType.bodyEmphasized)
                        Spacer()
                        Label(status.label, systemImage: status.symbol)
                            .font(NookType.caption)
                            .foregroundStyle(statusTint(status))
                    }
                    .padding(.vertical, 11)

                    if permission != NookPermission.allCases.last {
                        SoftDivider()
                    }
                }
            }
            .padding(.horizontal, 17)
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
                .stroke(.primary.opacity(0.09), lineWidth: 0.7)
            }
            .padding(.horizontal, 80)
            .padding(.top, 23)

            Toggle(
                isOn: Binding(
                    get: { detector.isEnabled },
                    set: { detector.isEnabled = $0 }
                )
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notice likely meetings")
                        .font(NookType.control)
                    Text("Nook checks local meeting activity and always asks before recording.")
                        .font(NookType.micro)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .padding(.horizontal, 84)
            .padding(.top, 18)

            Spacer()
        }
    }

    @ViewBuilder
    private var setupFooter: some View {
        HStack(spacing: 14) {
            if step != .introduction {
                Button("Back") {
                    move(to: WelcomeStep(rawValue: step.rawValue - 1) ?? .introduction)
                }
                .buttonStyle(.plain)
                .font(NookType.control)
            }

            Spacer()

            if let permission = step.permission {
                if permissions.status(for: permission) != .allowed {
                    Button("Not now") {
                        advance()
                    }
                    .buttonStyle(.plain)
                    .font(NookType.control)
                    .foregroundStyle(.secondary)
                }

                permissionButton(permission)
            } else if step == .ready {
                Button("Open library") {
                    finishWelcome()
                    openLibraryAction()
                }
                .buttonStyle(.plain)
                .font(NookType.control)

                Button("Done") {
                    finishWelcome()
                }
                .buttonStyle(
                    NookButtonStyle(
                        tint: NookPalette.accent,
                        isProminent: true
                    )
                )
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") {
                    advance()
                }
                .buttonStyle(
                    NookButtonStyle(
                        tint: NookPalette.accent,
                        isProminent: true
                    )
                )
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 28)
        .frame(height: 62)
        .overlay(alignment: .top) {
            SoftDivider()
        }
    }

    private func permissionButton(_ permission: NookPermission) -> some View {
        let status = permissions.status(for: permission)
        let isBusy = permissions.permissionInFlight == permission
        let title: String = switch status {
        case .notRequested:
            permission.requestActionTitle
        case .allowed:
            "Continue"
        case .needsAttention:
            "Open System Settings"
        }

        return Button {
            switch status {
            case .notRequested:
                Task {
                    await permissions.request(permission)
                }
            case .allowed:
                advance()
            case .needsAttention:
                permissions.openSettings(for: permission)
            }
        } label: {
            HStack(spacing: 7) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(title)
            }
        }
        .buttonStyle(
            NookButtonStyle(
                tint: NookPalette.accent,
                isProminent: true
            )
        )
        .keyboardShortcut(.defaultAction)
        .disabled(permissions.permissionInFlight != nil)
    }

    private func statusTint(_ status: NookPermissionStatus) -> Color {
        switch status {
        case .notRequested:
            .secondary
        case .allowed:
            NookPalette.success
        case .needsAttention:
            NookPalette.warning
        }
    }

    private func advance() {
        guard let next = WelcomeStep(rawValue: step.rawValue + 1) else { return }
        move(to: next)
    }

    private func move(to destination: WelcomeStep) {
        previewTask?.cancel()
        previewTask = nil
        permissions.refresh()
        withAnimation(reduceMotion ? nil : NookMotion.spatial) {
            step = destination
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
        completeWelcomeAction()
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
