import AppKit
import Combine
import SwiftUI

/// Bridges an optional `CalendarContextService` into SwiftUI's observation.
///
/// `@ObservedObject` requires a non-optional `ObservableObject`, but the
/// calendar service itself is legitimately absent outside the running app
/// (previews, the snapshot tool). This forwards the wrapped service's own
/// publishes so the view still re-renders when it is present, without
/// forcing every call site to invent a non-optional stand-in.
@MainActor
private final class OptionalCalendarObserver: ObservableObject {
    let calendar: CalendarContextService?
    private var cancellable: AnyCancellable?

    init(_ calendar: CalendarContextService?) {
        self.calendar = calendar
        cancellable = calendar?.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}

enum WelcomeStep: Int, CaseIterable {
    case introduction
    case microphone
    case speechRecognition
    case screenRecording
    case calendar
    case dictation
    case ready

    var permission: NookPermission? {
        switch self {
        case .screenRecording:
            .screenRecording
        case .microphone:
            .microphone
        case .speechRecognition:
            .speechRecognition
        case .introduction, .calendar, .dictation, .ready:
            nil
        }
    }
}

struct WelcomeView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var detector: MeetingDetector
    /// Absent when onboarding is rendered outside the running app, such as in
    /// the snapshot tool, where there is no coordinator to speak of.
    private let dictation: DictationCoordinator?
    /// Optional for the same reason as `dictation`; observed through
    /// `OptionalCalendarObserver` so a denied access prompt updates the
    /// toggle and shows the denial message instead of sitting stale.
    @StateObject private var calendarObserver: OptionalCalendarObserver
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
        dictation = appModel.dictation
        _calendarObserver = StateObject(
            wrappedValue: OptionalCalendarObserver(appModel.calendar)
        )
        completeWelcomeAction = { appModel.completeWelcome() }
        openLibraryAction = { appModel.openLibrary() }
    }

    init(
        detector: MeetingDetector,
        initialStep: WelcomeStep = .introduction
    ) {
        _detector = ObservedObject(wrappedValue: detector)
        _step = State(initialValue: initialStep)
        dictation = nil
        _calendarObserver = StateObject(
            wrappedValue: OptionalCalendarObserver(nil)
        )
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
                    case .calendar:
                        calendarIntroduction
                    case .dictation:
                        dictationIntroduction
                    case .ready:
                        ready
                    }
                }
                .id(step)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .move(edge: .trailing))
                )

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
                WelcomeStepArt {
                    NookPresence(
                        state: .resting,
                        size: 44,
                        showsSurface: false
                    )
                }

                Text("Meetings, tucked away.")
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
                WelcomeStepArt(symbol: permission.symbol)

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
                        : "You may see two macOS alerts. Nook only checks access here, nothing is recorded or saved."
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

    /// Optional calendar context, offered at the one moment it makes sense.
    ///
    /// The switch is the only place access is ever requested: turning it on
    /// asks, leaving it off never does, and either choice can be revisited in
    /// Settings. Recording still prompts on its own afterwards.
    private var calendarIntroduction: some View {
        VStack(spacing: 0) {
            VStack(spacing: 9) {
                WelcomeStepArt(symbol: "calendar.badge.clock")

                Text("Name meetings after their event")
                    .font(NookType.title)

                Text("With your calendar, Nook calls a meeting what your calendar calls it, and mentions an event shortly before it starts.")
                    .font(NookType.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 440)
            }
            .padding(.top, 27)

            VStack(spacing: 12) {
                if let calendar = calendarObserver.calendar {
                    Toggle(
                        isOn: Binding(
                            get: { calendar.isEnabled },
                            set: { enabled in
                                Task { await calendar.setEnabled(enabled) }
                            }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Use my calendar for meeting context")
                                .font(NookType.control)
                            Text("Read on this Mac only. Nook will ask for Calendar access if you turn this on.")
                                .font(NookType.micro)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    if calendar.accessDenied {
                        Label(
                            "Calendar access was declined. Allow Nook in System Settings, Privacy & Security, Calendars.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(NookType.caption)
                        .foregroundStyle(NookPalette.danger)
                        .frame(maxWidth: 430, alignment: .leading)
                    }
                }

                Text("Nook reads the calendars already set up on this Mac, such as iCloud, Google, or Exchange. Missing one? Add it in System Settings, Internet Accounts.")
                    .font(NookType.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)

                Text("Either way, Nook always asks before recording anything.")
                    .font(NookType.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 84)
            .padding(.top, 26)

            Spacer()
        }
    }

    private var ready: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                WelcomeStepArt {
                    NookPresence(
                        state: permissions.allPermissionsAllowed
                            ? .saved
                            : .resting,
                        size: 44,
                        showsSurface: false
                    )
                }

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
            .padding(.top, 22)

            // Card, switch and tips share one inner edge. They used to be laid
            // out with three different insets, and each block also hugged its
            // own content, so nothing on the last screen lined up with
            // anything else on it.
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(NookPermission.allCases) { permission in
                        permissionSummaryRow(permission)

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
                .padding(.horizontal, 17)
                .padding(.top, 18)

                VStack(alignment: .leading, spacing: 8) {
                    worthKnowingRow(
                        symbol: "flag",
                        text: "Flag a moment while recording with ⌥⌘F, and play it back later."
                    )
                    worthKnowingRow(
                        symbol: "sparkle.magnifyingglass",
                        text: "Ask your library anything in the toolbar; answers cite their meetings."
                    )
                    worthKnowingRow(
                        symbol: "newspaper",
                        text: "Compile the week into one digest note whenever you like."
                    )
                }
                .padding(.horizontal, 17)
                .padding(.top, 13)
                .accessibilityElement(children: .combine)
            }
            .padding(.horizontal, 80)
            .padding(.top, 18)

            Spacer()
        }
    }

    /// One permission on the last screen. A row that only reports "Not set up"
    /// leaves the user to guess where setting it up happens, so it offers the
    /// same action the step for that permission would have offered.
    private func permissionSummaryRow(
        _ permission: NookPermission
    ) -> some View {
        let status = permissions.status(for: permission)

        return HStack(spacing: 11) {
            Image(systemName: permission.symbol)
                .foregroundStyle(NookPalette.accent)
                .symbolRenderingMode(.monochrome)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(permission.title)
                .font(NookType.bodyEmphasized)
            Spacer(minLength: 9)
            Label(status.label, systemImage: status.symbol)
                .font(NookType.caption)
                .foregroundStyle(statusTint(status))
                .accessibilityLabel("\(permission.title): \(status.label)")

            if status != .allowed {
                Button(status == .needsAttention ? "Open Settings" : "Set up") {
                    resolve(permission)
                }
                .buttonStyle(NookButtonStyle(tint: NookPalette.accent))
                .disabled(permissions.permissionInFlight != nil)
                .accessibilityLabel("Set up \(permission.title)")
            }
        }
        // Sized around the button rather than the text, so a row offering an
        // action is not taller than the rows beside it.
        .frame(minHeight: 34)
        .padding(.vertical, 5)
    }

    /// The same branch the footer button takes, so the two cannot drift apart.
    private func resolve(_ permission: NookPermission) {
        switch permissions.status(for: permission) {
        case .notRequested:
            Task { await permissions.request(permission) }
        case .needsAttention:
            permissions.openSettings(for: permission)
        case .allowed:
            break
        }
    }

    private func worthKnowingRow(symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .foregroundStyle(NookPalette.accent)
                .symbolRenderingMode(.monochrome)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(text)
                .font(NookType.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Introduces dictation and the spoken note.
    ///
    /// Placed after the recording permissions because it is a second thing
    /// Nook does, not a condition of the first. Someone who only wants meeting
    /// notes can pass straight through it, and nothing is requested here:
    /// Accessibility is asked for the first time dictation actually runs.
    private var dictationIntroduction: some View {
        VStack(spacing: 0) {
            VStack(spacing: 9) {
                WelcomeStepArt(symbol: "mic.and.signal.meter")

                Text("Speak anywhere on your Mac")
                    .font(NookType.title)

                Text("Hold a shortcut, say the thing, let go. Nook types it where you are already working.")
                    .font(NookType.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)
            }
            .padding(.top, 27)

            VStack(spacing: 0) {
                dictationHighlight(
                    symbol: "text.cursor",
                    title: "Into any text field",
                    detail: "A message, a search box, a document. Your words appear as you speak them."
                )
                SoftDivider()
                dictationHighlight(
                    symbol: "note.text",
                    title: "Or into a quick note",
                    detail: "With nothing selected, Nook opens a small note instead, so a thought can land without opening anything first."
                )
                SoftDivider()
                dictationHighlight(
                    symbol: "wand.and.sparkles",
                    title: "Tidied as you like",
                    detail: "Keep every word, drop the hesitations, or have rambling speech rewritten as clear prose."
                )
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

            if let dictation {
                Toggle(
                    isOn: Binding(
                        get: { dictation.isEnabled },
                        set: { dictation.isEnabled = $0 }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Turn on dictation")
                            .font(NookType.control)
                        Text("Uses \(dictation.shortcut.displayString). Nook will ask for Accessibility access the first time you use it, so it can type into other apps.")
                            .font(NookType.micro)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 84)
                .padding(.top, 18)
            }

            Spacer()
        }
    }

    private func dictationHighlight(
        symbol: String,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .foregroundStyle(NookPalette.accent)
                .frame(width: 20)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(NookType.bodyEmphasized)
                Text(detail)
                    .font(NookType.micro)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
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
                withAnimation(
                    step == 3
                        ? NookMotion.settle(over: 0.64)
                        : NookMotion.spatial
                ) {
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

/// One header treatment for every setup step.
///
/// The steps used to disagree: a tinted disc on the permission screens, a bare
/// glyph on calendar, the brand mark on the first and last, and on dictation a
/// symbol name that does not exist in SF Symbols, so nothing at all. Walking
/// forward through setup looked like walking through four different apps.
private struct WelcomeStepArt<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(NookPalette.accent.opacity(0.11))
                .frame(width: 74, height: 74)
            content
        }
        .accessibilityHidden(true)
    }
}

private struct WelcomeStepSymbol: View {
    let name: String

    var body: some View {
        Image(systemName: name)
            .font(.largeTitle)
            .foregroundStyle(NookPalette.accent)
            // Several of these symbols have a multicolour variant that macOS
            // prefers, which put a stock blue glyph in a tinted Nook circle.
            .symbolRenderingMode(.monochrome)
    }
}

extension WelcomeStepArt where Content == WelcomeStepSymbol {
    init(symbol: String) {
        self.init { WelcomeStepSymbol(name: symbol) }
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
                    systemImage: step >= 3
                        ? "text.badge.checkmark"
                        : "text.alignleft"
                )
                .font(NookType.metadata)
                .foregroundStyle(step >= 3 ? NookPalette.accent : .secondary)

                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "circle")
                        .font(.system(size: 5, weight: .bold))
                        .foregroundStyle(NookPalette.accent)
                    // This is the state the screen opens in and the only state
                    // Reduce Motion ever shows, so the sentence the whole
                    // preview is about has to be readable before anything
                    // animates. Tertiary measured 1.9:1 and plain secondary
                    // 4.0:1 on this surface; both fail at 13pt. The resting
                    // style is still visibly lighter than the settled one.
                    Text("Send revised brief · Friday")
                        .font(NookType.bodyEmphasized)
                        .foregroundStyle(
                            step >= 2
                                ? AnyShapeStyle(.primary)
                                : AnyShapeStyle(Color.primary.opacity(0.66))
                        )
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
