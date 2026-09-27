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
    /// Which way the last move went, so content leaves toward where it came
    /// from when the user goes back.
    @State private var movesForward = true
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
            WelcomeBackdrop()

            VStack(spacing: 0) {
                WelcomeProgress(current: step.rawValue, count: WelcomeStep.allCases.count)
                    .padding(.top, 16)

                // The stage stays put between steps; only its scene changes,
                // so the window reads as one continuous demonstration.
                WelcomeStage(scene: step.stageScene)
                    .padding(.top, 16)

                // Centred between the stage and the footer, so a short step
                // sits in the middle of its space instead of under a void.
                ZStack {
                    stepContent
                        .id(step)
                        .transition(stepTransition)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 12)

                setupFooter
            }
        }
        .frame(
            minWidth: 680,
            idealWidth: 700,
            maxWidth: .infinity,
            minHeight: 660,
            idealHeight: 680,
            maxHeight: .infinity
        )
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            permissions.refreshAfterBecomingActive()
        }
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let shift: CGFloat = movesForward ? 28 : -28
        return .asymmetric(
            insertion: .modifier(
                active: WelcomeStepEffect(offset: shift, progress: 0),
                identity: WelcomeStepEffect(offset: shift, progress: 1)
            )
            .animation(.spring(response: 0.46, dampingFraction: 0.86).delay(0.06)),
            removal: .modifier(
                active: WelcomeStepEffect(offset: -shift, progress: 0),
                identity: WelcomeStepEffect(offset: -shift, progress: 1)
            )
            .animation(.easeIn(duration: 0.16))
        )
    }

    @ViewBuilder
    private var stepContent: some View {
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

    private func header(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(NookType.largeTitle)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(detail)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 470)
        }
        .padding(.horizontal, 40)
    }

    // MARK: Steps

    private var introduction: some View {
        VStack(spacing: 18) {
            header(
                "Meetings, tucked away.",
                "Nook lives in the notch. It notices a meeting, keeps the words, "
                    + "finds what matters, and saves a plain Markdown note on this Mac."
            )

            HStack(spacing: 18) {
                WelcomePromise(symbol: "lock.fill", text: "On-device transcription")
                WelcomePromise(symbol: "sparkles", text: "Local summaries")
                WelcomePromise(symbol: "doc.plaintext.fill", text: "Plain Markdown")
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func permissionSetup(_ permission: NookPermission) -> some View {
        let status = permissions.status(for: permission)

        return VStack(spacing: 18) {
            header(permission.title, permission.setupDescription)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(NookPalette.accent)
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Why Nook asks")
                            .font(NookType.bodyEmphasized)
                        Text(permission.privacyExplanation)
                            .font(NookType.caption)
                            .foregroundStyle(.secondary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()

                HStack(spacing: 9) {
                    Image(systemName: status.symbol)
                        .foregroundStyle(statusTint(status))
                        .contentTransition(.symbolEffect(.replace))
                    Text(status.label)
                        .font(NookType.body)
                    Spacer()
                    Text("macOS controls this permission")
                        .font(NookType.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(permission.title): \(status.label)")
            }
            .padding(10)
            .nookGroupBox()
            .frame(maxWidth: 520)

            if permission == .screenRecording {
                Text(
                    status == .allowed
                        ? "Both macOS access checks are complete. No test recording was created."
                        : "You may see two macOS alerts. Nook only checks access here, nothing is recorded or saved."
                )
                .font(NookType.micro)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            }
        }
        .padding(.horizontal, 40)
    }

    /// Optional calendar context, offered at the one moment it makes sense.
    ///
    /// The switch is the only place access is ever requested: turning it on
    /// asks, leaving it off never does, and either choice can be revisited in
    /// Settings. Recording still prompts on its own afterwards.
    private var calendarIntroduction: some View {
        VStack(spacing: 16) {
            header(
                "Name meetings after their event",
                "With your calendar, Nook calls a meeting what your calendar calls it, and mentions an event shortly before it starts."
            )

            VStack(spacing: 10) {
                if let calendar = calendarObserver.calendar {
                    WelcomeSwitchRow(
                        title: "Use my calendar for meeting context",
                        detail: "Read on this Mac only. Nook will ask for Calendar access if you turn this on.",
                        isOn: Binding(
                            get: { calendar.isEnabled },
                            set: { enabled in
                                Task { await calendar.setEnabled(enabled) }
                            }
                        )
                    )

                    if calendar.accessDenied {
                        Label(
                            "Calendar access was declined. Allow Nook in System Settings, Privacy & Security, Calendars.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(NookType.caption)
                        .foregroundStyle(NookPalette.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Text("Nook reads the calendars already set up on this Mac, such as iCloud, Google, or Exchange. Either way, it always asks before recording anything.")
                    .font(NookType.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 520)
        }
        .padding(.horizontal, 40)
    }

    /// Introduces dictation and the spoken note.
    ///
    /// Placed after the recording permissions because it is a second thing
    /// Nook does, not a condition of the first. Someone who only wants meeting
    /// notes can pass straight through it, and nothing is requested here:
    /// Accessibility is asked for the first time dictation actually runs.
    private var dictationIntroduction: some View {
        VStack(spacing: 16) {
            header(
                "Speak anywhere on your Mac",
                "Hold a shortcut, say the thing, let go. Nook types it where you are already working, or opens a quick note when nothing is selected."
            )

            if let dictation {
                WelcomeSwitchRow(
                    title: "Turn on dictation",
                    detail: "Uses \(dictation.shortcut.displayString). Nook will ask for Accessibility access the first time you use it, so it can type into other apps.",
                    isOn: Binding(
                        get: { dictation.isEnabled },
                        set: { dictation.isEnabled = $0 }
                    )
                )
                .frame(maxWidth: 520)
            } else {
                HStack(spacing: 18) {
                    WelcomePromise(symbol: "text.cursor", text: "Any text field")
                    WelcomePromise(symbol: "note.text", text: "Or a quick note")
                    WelcomePromise(symbol: "wand.and.sparkles", text: "Tidied as you like")
                }
            }
        }
        .padding(.horizontal, 40)
    }

    private var ready: some View {
        VStack(spacing: 14) {
            header(
                permissions.allPermissionsAllowed
                    ? "Nook is ready."
                    : "You’re ready to explore.",
                permissions.allPermissionsAllowed
                    ? "Start a recording whenever a meeting begins. Nook keeps the note on this Mac."
                    : "Finish any missing permissions now, or when you start your first recording."
            )

            // Card and switch share one inner edge, so nothing on the last
            // screen sits out of line with anything else on it.
            VStack(spacing: 10) {
                VStack(spacing: 0) {
                    ForEach(NookPermission.allCases) { permission in
                        permissionSummaryRow(permission)

                        if permission != NookPermission.allCases.last {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 8)
                .nookGroupBox()

                WelcomeSwitchRow(
                    title: "Notice likely meetings",
                    detail: "Nook checks local meeting activity and always asks before recording.",
                    isOn: Binding(
                        get: { detector.isEnabled },
                        set: { detector.isEnabled = $0 }
                    )
                )
            }
            .frame(maxWidth: 540)
        }
        .padding(.horizontal, 40)
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
                .font(NookType.body)
            Spacer(minLength: 9)
            Label(status.label, systemImage: status.symbol)
                .font(NookType.caption)
                .foregroundStyle(statusTint(status))
                .contentTransition(.symbolEffect(.replace))
                .accessibilityLabel("\(permission.title): \(status.label)")

            if status != .allowed {
                Button(status == .needsAttention ? "Open Settings" : "Set Up") {
                    resolve(permission)
                }
                .buttonStyle(.bordered)
                .disabled(permissions.permissionInFlight != nil)
                .accessibilityLabel("Set up \(permission.title)")
            }
        }
        // Sized around the button rather than the text, so a row offering an
        // action is not taller than the rows beside it.
        .frame(minHeight: 34)
        .padding(.vertical, 3)
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

    /// Laid out like Setup Assistant: Back on the leading edge, the step's
    /// action on the trailing edge, standard large buttons, no rule above.
    private var setupFooter: some View {
        HStack(spacing: 12) {
            if step != .introduction {
                Button("Back") {
                    move(to: WelcomeStep(rawValue: step.rawValue - 1) ?? .introduction)
                }
            }

            if step != .ready {
                Button("Set Up Later") {
                    finishWelcome()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close setup. Nook asks for anything it still needs when you first use it.")
            }

            Spacer()

            if let permission = step.permission {
                if permissions.status(for: permission) != .allowed {
                    Button("Not Now") {
                        advance()
                    }
                }

                permissionButton(permission)
            } else if step == .ready {
                Button("Open Library") {
                    finishWelcome()
                    openLibraryAction()
                }

                Button("Done") {
                    finishWelcome()
                }
                .buttonStyle(.borderedProminent)
                .tint(NookPalette.accentFill)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") {
                    advance()
                }
                .buttonStyle(.borderedProminent)
                .tint(NookPalette.accentFill)
                .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Setup step \(step.rawValue + 1) of \(WelcomeStep.allCases.count)")
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
        .buttonStyle(.borderedProminent)
        .tint(NookPalette.accentFill)
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
        permissions.refresh()
        movesForward = destination.rawValue >= step.rawValue
        withAnimation(reduceMotion ? nil : NookMotion.morph) {
            step = destination
        }
    }

    private func finishWelcome() {
        completeWelcomeAction()
        dismissWindow(id: "welcome")
    }
}


// MARK: - Motion

private struct WelcomeStepEffect: ViewModifier {
    let offset: CGFloat
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .blur(radius: (1 - progress) * 6)
            .offset(x: (1 - progress) * offset)
    }
}

// MARK: - Backdrop and progress

/// A slow lagoon mesh behind the whole window, the only colour in an
/// otherwise native setup. It drifts; Reduce Motion holds it still.
private struct WelcomeBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let drift = Float(sin(time * 0.23)) * 0.08
            let sway = Float(cos(time * 0.17)) * 0.08
            MeshGradient(
                width: 3,
                height: 3,
                points: [
                    [0, 0], [0.5 + drift, 0], [1, 0],
                    [0, 0.5 + sway], [0.5 - drift, 0.45 + sway], [1, 0.5 - sway],
                    [0, 1], [0.5 + sway, 1], [1, 1],
                ],
                colors: colorScheme == .dark ? darkColors : lightColors
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var lightColors: [Color] {
        [
            Color(red: 0.93, green: 0.99, blue: 0.97), Color(red: 0.97, green: 1.00, blue: 0.99), Color(red: 0.94, green: 0.97, blue: 1.00),
            Color(red: 0.97, green: 0.99, blue: 0.99), Color(red: 0.86, green: 0.97, blue: 0.94), Color(red: 0.98, green: 0.98, blue: 1.00),
            Color.white, Color(red: 0.95, green: 0.99, blue: 0.98), Color.white,
        ]
    }

    private var darkColors: [Color] {
        [
            Color(red: 0.05, green: 0.09, blue: 0.10), Color(red: 0.06, green: 0.16, blue: 0.16), Color(red: 0.06, green: 0.08, blue: 0.12),
            Color(red: 0.06, green: 0.12, blue: 0.13), Color(red: 0.05, green: 0.20, blue: 0.19), Color(red: 0.08, green: 0.09, blue: 0.13),
            Color(red: 0.04, green: 0.06, blue: 0.07), Color(red: 0.05, green: 0.10, blue: 0.10), Color(red: 0.04, green: 0.05, blue: 0.07),
        ]
    }
}

/// Where setup is, without a "Step 3 of 7" label: the current step is the
/// one stretched into a capsule.
private struct WelcomeProgress: View {
    let current: Int
    let count: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index <= current ? AnyShapeStyle(NookPalette.accent) : AnyShapeStyle(.primary.opacity(0.14)))
                    .frame(width: index == current ? 22 : 6, height: 6)
                    .opacity(index < current ? 0.45 : 1)
            }
        }
        .animation(reduceMotion ? nil : NookMotion.morph, value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Setup step \(current + 1) of \(count)")
    }
}

private struct WelcomePromise: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(NookPalette.accent)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Stage

/// What the stage is demonstrating for each step.
private enum WelcomeScene: Equatable {
    case story
    case voice
    case words
    case meeting
    case calendar
    case dictation
    case ready

    /// The story is the hero and gets the room; the last step needs space
    /// for its checklist. The stage morphs between heights as steps change.
    var stageHeight: CGFloat {
        switch self {
        case .story: 300
        case .ready: 176
        default: 214
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .story: "Animation: Nook notices a meeting at the notch, records it, and saves a note."
        case .voice: "Animation: your own words appear in the notch as you speak."
        case .words: "Animation: speech in the meeting turns into captions."
        case .meeting: "Animation: Nook hears the meeting app and captions the other side."
        case .calendar: "Animation: a calendar event names the meeting Nook offers to record."
        case .dictation: "Animation: spoken words are typed into a message."
        case .ready: "Animation: a meeting note, saved and tucked away."
        }
    }
}

extension WelcomeStep {
    fileprivate var stageScene: WelcomeScene {
        switch self {
        case .introduction: .story
        case .microphone: .voice
        case .speechRecognition: .words
        case .screenRecording: .meeting
        case .calendar: .calendar
        case .dictation: .dictation
        case .ready: .ready
        }
    }
}

private struct MiniCaption: Equatable, Identifiable {
    let speaker: String
    let isYou: Bool
    let text: String
    var id: String { speaker + text }
}

/// What the miniature island is doing at one beat of a scene.
private enum MiniIslandState: Equatable {
    case closed
    case prompt(title: String, detail: String)
    case ears
    case captions([MiniCaption])
    case writing
    case saved
    case dictating

    var size: CGSize {
        switch self {
        case .closed: CGSize(width: 84, height: 20)
        case .prompt: CGSize(width: 280, height: 62)
        case .ears: CGSize(width: 196, height: 20)
        case .captions(let lines): CGSize(width: 340, height: 34 + CGFloat(max(1, lines.count)) * 19)
        case .writing: CGSize(width: 236, height: 56)
        case .saved: CGSize(width: 244, height: 58)
        case .dictating: CGSize(width: 196, height: 20)
        }
    }

    var identity: String {
        switch self {
        case .closed: "closed"
        case .prompt: "prompt"
        case .ears, .dictating: "ears"
        case .captions: "captions"
        case .writing: "writing"
        case .saved: "saved"
        }
    }
}

private struct StageBeat {
    var island: MiniIslandState
    var seconds: Double
    var showsNote = false
    /// The call on screen while the meeting is happening.
    var showsCall = false
}

/// A small MacBook screen with the notch at the top, where each setup step
/// shows what it is for.
private struct WelcomeStage: View {
    let scene: WelcomeScene

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var beatIndex = 0
    @State private var loop: Task<Void, Never>?

    private static let width: CGFloat = 520

    private var beats: [StageBeat] {
        let meetingLine = MiniCaption(speaker: "Meeting", isYou: false, text: "Can we ship the new prompt on Friday?")
        let yourLine = MiniCaption(speaker: "You", isYou: true, text: "Yes, after tomorrow’s review.")
        switch scene {
        case .story:
            return [
                StageBeat(island: .prompt(title: "Design review", detail: "Teams · Record this meeting?"), seconds: 2.0, showsCall: true),
                StageBeat(island: .ears, seconds: 1.5, showsCall: true),
                StageBeat(island: .captions([meetingLine]), seconds: 1.3, showsCall: true),
                StageBeat(island: .captions([meetingLine, yourLine]), seconds: 1.8, showsCall: true),
                StageBeat(island: .writing, seconds: 1.5),
                StageBeat(island: .closed, seconds: 2.8, showsNote: true),
            ]
        case .voice:
            return [
                StageBeat(island: .ears, seconds: 1.3),
                StageBeat(island: .captions([yourLine]), seconds: 2.8),
            ]
        case .words:
            return [
                StageBeat(island: .ears, seconds: 1.0),
                StageBeat(island: .captions([meetingLine]), seconds: 1.4),
                StageBeat(island: .captions([meetingLine, yourLine]), seconds: 2.4),
            ]
        case .meeting:
            return [
                StageBeat(island: .ears, seconds: 1.2),
                StageBeat(island: .captions([meetingLine]), seconds: 2.8),
            ]
        case .calendar:
            return [
                StageBeat(island: .closed, seconds: 0.9),
                StageBeat(island: .prompt(title: "Design review", detail: "Calendar · starts at 10:00"), seconds: 3.2),
            ]
        case .dictation:
            return [StageBeat(island: .dictating, seconds: 4.2)]
        case .ready:
            return [
                StageBeat(island: .saved, seconds: 2.4, showsNote: true),
                StageBeat(island: .ears, seconds: 1.8, showsNote: true),
            ]
        }
    }

    /// The richest moment of each scene, which is all Reduce Motion shows.
    private var restingBeat: StageBeat {
        switch scene {
        case .story: StageBeat(island: .closed, seconds: 0, showsNote: true)
        case .voice, .meeting: beats[1]
        case .words: beats[2]
        case .calendar: beats[1]
        case .dictation, .ready: beats[0]
        }
    }

    private var beat: StageBeat {
        reduceMotion ? restingBeat : beats[min(beatIndex, beats.count - 1)]
    }

    var body: some View {
        ZStack(alignment: .top) {
            StageWallpaper()

            StageMenuBar()

            if scene == .story, beat.showsCall {
                StageMeetingWindow()
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.94))
                    )
            }

            Group {
                switch scene {
                case .meeting: StageMeetingWindow().transition(.opacity)
                case .calendar: StageCalendarBanner().transition(.opacity)
                case .dictation: StageMessageField(reduceMotion: reduceMotion).transition(.opacity)
                default: EmptyView()
                }
            }

            if beat.showsNote {
                StageNoteCard()
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
            }

            MiniIsland(state: beat.island)

            // The camera housing itself, which the island grows out of.
            UnevenRoundedRectangle(
                bottomLeadingRadius: 7,
                bottomTrailingRadius: 7,
                style: .continuous
            )
            .fill(Color.black)
            .frame(width: 84, height: 20)

            if scene == .ready {
                CelebrationBurst()
                    .offset(y: 30)
            }
        }
        .frame(width: Self.width, height: scene.stageHeight, alignment: .top)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10, style: .continuous))
        // A MacBook: thin bezel, then the base with its thumb notch.
        .padding([.top, .horizontal], 7)
        .padding(.bottom, 9)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16, style: .continuous)
                .fill(Color(red: 0.07, green: 0.08, blue: 0.09))
                .overlay {
                    UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                }
        )
        .overlay(alignment: .bottom) {
            StageBase(width: Self.width + 60)
                .offset(y: 10)
        }
        .padding(.bottom, 10)
        .shadow(color: .black.opacity(0.28), radius: 24, y: 14)
        .environment(\.colorScheme, .dark)
        .animation(reduceMotion ? nil : NookMotion.morph, value: beatIndex)
        .animation(reduceMotion ? nil : NookMotion.morph, value: scene)
        .onAppear(perform: restart)
        .onChange(of: scene) { _, _ in restart() }
        .onDisappear { loop?.cancel() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(scene.accessibilityDescription)
    }

    private func restart() {
        loop?.cancel()
        beatIndex = 0
        guard !reduceMotion else { return }
        loop = Task { @MainActor in
            while !Task.isCancelled {
                let current = beats[min(beatIndex, beats.count - 1)]
                try? await Task.sleep(for: .seconds(current.seconds))
                guard !Task.isCancelled else { return }
                beatIndex = (beatIndex + 1) % beats.count
            }
        }
    }
}

private struct StageWallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.22, blue: 0.26),
                    Color(red: 0.08, green: 0.11, blue: 0.19),
                    Color(red: 0.16, green: 0.10, blue: 0.20),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [NookPalette.accent.opacity(0.28), .clear],
                center: .init(x: 0.5, y: 0.05),
                startRadius: 0,
                endRadius: 240
            )
        }
    }
}

private struct StageMenuBar: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "apple.logo")
                .font(.system(size: 8.5))
            ForEach([26, 20, 18, 24], id: \.self) { width in
                Capsule().frame(width: CGFloat(width), height: 4)
            }
            Spacer()
            ForEach([10, 14, 30], id: \.self) { width in
                Capsule().frame(width: CGFloat(width), height: 4)
            }
        }
        .foregroundStyle(.white.opacity(0.55))
        .padding(.horizontal, 12)
        .frame(height: 20)
        .background(.black.opacity(0.22))
        .accessibilityHidden(true)
    }
}

/// The notch island in miniature, with the real island's shape, rim light
/// and choreography.
private struct MiniIsland: View {
    let state: MiniIslandState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let size = state.size
        let shape = NotchIslandShape(bottomRadius: state == .closed ? 7 : 12, shoulder: 5)
        ZStack(alignment: .top) {
            shape.fill(Color.black)
            content
                .frame(width: size.width, height: size.height, alignment: .top)
                .id(state.identity)
                .transition(miniContent)
            shape
                .stroke(
                    LinearGradient(
                        colors: [.clear, NookPalette.accentHighlight.opacity(state == .closed ? 0 : 0.8), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 1
                )
                .mask(LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom))
        }
        .frame(width: size.width + 10, height: size.height)
        .clipShape(shape)
        .shadow(color: .black.opacity(state == .closed ? 0 : 0.45), radius: 10, y: 5)
    }

    private var miniContent: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .modifier(
                active: MiniContentEffect(progress: 0),
                identity: MiniContentEffect(progress: 1)
            )
            .animation(.spring(response: 0.4, dampingFraction: 0.86).delay(0.1)),
            removal: .modifier(
                active: MiniContentEffect(progress: 0),
                identity: MiniContentEffect(progress: 1)
            )
            .animation(.easeIn(duration: 0.12))
        )
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .closed:
            Color.clear
        case .prompt(let title, let detail):
            VStack(spacing: 0) {
                Color.clear.frame(height: 20)
                HStack(spacing: 8) {
                    MiniPulse()
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title)
                            .font(.system(size: 10, weight: .semibold))
                        Text(detail)
                            .font(.system(size: 8.5))
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 4)
                    HStack(spacing: 4) {
                        RecordGlyph()
                            .frame(width: 9, height: 9)
                        Text("Record")
                    }
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(NookPalette.notchInk)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(NookPalette.accent, in: Capsule())
                        .shadow(color: NookPalette.accent.opacity(0.5), radius: 5)
                }
                .padding(.horizontal, 12)
                .frame(maxHeight: .infinity)
            }
        case .ears, .dictating:
            HStack {
                if state == .dictating {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(NookPalette.accentHighlight)
                } else {
                    MiniWaveform()
                        .frame(width: 24, height: 10)
                }
                Spacer()
                if state == .ears {
                    MiniClock()
                } else {
                    MiniWaveform()
                        .frame(width: 24, height: 10)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 20)
        case .captions(let lines):
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    MiniWaveform().frame(width: 24, height: 10)
                    Spacer()
                    MiniClock()
                }
                .frame(height: 20)
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    HStack(spacing: 6) {
                        Image(systemName: line.isYou ? "person.crop.circle.fill" : "quote.bubble.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(line.isYou ? Color.white.opacity(0.7) : NookPalette.accentHighlight)
                        Text(line.text)
                            .font(.system(size: 10, weight: index == lines.count - 1 ? .semibold : .regular))
                            .foregroundStyle(.white.opacity(index == lines.count - 1 ? 1 : 0.6))
                            .lineLimit(1)
                    }
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .modifier(
                                active: MiniContentEffect(progress: 0),
                                identity: MiniContentEffect(progress: 1)
                            )
                    )
                }
            }
            .padding(.horizontal, 12)
        case .writing:
            VStack(spacing: 0) {
                Color.clear.frame(height: 20)
                HStack(spacing: 8) {
                    MiniTypingDots()
                    Text("Tucking this conversation away")
                        .font(.system(size: 9.5, weight: .semibold))
                        .lineLimit(1)
                }
                .frame(maxHeight: .infinity)
            }
        case .saved:
            VStack(spacing: 0) {
                Color.clear.frame(height: 20)
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(NookPalette.notchInk, NookPalette.notchAccent)
                        .symbolEffect(.bounce, value: state)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Tucked away")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Design review · Saved as Markdown")
                            .font(.system(size: 8.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(maxHeight: .infinity)
            }
        }
    }
}

private struct MiniContentEffect: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .blur(radius: (1 - progress) * 5)
            .scaleEffect(0.92 + 0.08 * progress, anchor: .top)
    }
}

/// A voice that is always talking, for the stage.
private struct MiniWaveform: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let envelope: [Double] = [0.5, 0.85, 1, 0.75, 0.55]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                let count = Self.envelope.count
                let barWidth = size.width / CGFloat(count * 2 - 1)
                let speech = reduceMotion ? 0.6 : 0.35 + 0.65 * abs(sin(time * 3.1)) * abs(sin(time * 1.3 + 0.4))
                for index in 0..<count {
                    let wobble = reduceMotion ? 0.8 : 0.6 + 0.4 * (sin(time * 9 + Double(index) * 1.8) + 1) / 2
                    let height = max(barWidth, size.height * (0.2 + 0.8 * speech * Self.envelope[index] * wobble))
                    let rect = CGRect(
                        x: CGFloat(index) * barWidth * 2,
                        y: (size.height - height) / 2,
                        width: barWidth,
                        height: height
                    )
                    canvas.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .color(NookPalette.accentHighlight)
                    )
                }
            }
        }
        .shadow(color: NookPalette.accent.opacity(0.7), radius: 2.5)
    }
}

private struct MiniClock: View {
    @State private var started = Date()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(NookElapsedTime.clock(12 * 60 + 4 + context.date.timeIntervalSince(started)))
                .font(.system(size: 9.5, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}

private struct MiniPulse: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(NookPalette.accent.opacity(0.18))
            Circle()
                .stroke(NookPalette.accent, lineWidth: 1)
                .phaseAnimator(reduceMotion ? [0.0] : [0.0, 1.0]) { ring, progress in
                    ring
                        .scaleEffect(0.45 + progress * 0.75)
                        .opacity(reduceMotion ? 0 : 0.8 * (1 - progress))
                } animation: { progress in
                    progress == 1 ? .easeOut(duration: 1.5) : .linear(duration: 0.01)
                }
            Circle()
                .fill(NookPalette.accentHighlight)
                .frame(width: 6, height: 6)
        }
        .frame(width: 20, height: 20)
    }
}

private struct MiniTypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    let wave = reduceMotion ? 0 : max(0, sin(time * 5.2 - Double(index) * 0.9))
                    Circle()
                        .fill(NookPalette.accentHighlight)
                        .frame(width: 4.5, height: 4.5)
                        .opacity(0.45 + wave * 0.55)
                        .offset(y: -wave * 2.5)
                }
            }
        }
    }
}

// MARK: - Stage props

/// The base of the laptop under the screen, with the thumb notch.
private struct StageBase: View {
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(
                topLeadingRadius: 3,
                bottomLeadingRadius: 12,
                bottomTrailingRadius: 12,
                topTrailingRadius: 3,
                style: .continuous
            )
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.78, green: 0.80, blue: 0.82),
                        Color(red: 0.55, green: 0.57, blue: 0.60),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            UnevenRoundedRectangle(
                bottomLeadingRadius: 5,
                bottomTrailingRadius: 5,
                style: .continuous
            )
            .fill(Color(red: 0.45, green: 0.47, blue: 0.50))
            .frame(width: 84, height: 4)
        }
        .frame(width: width, height: 11)
        .accessibilityHidden(true)
    }
}

/// The saved note, arriving in the library.
private struct StageNoteCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Design review")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.black.opacity(0.85))
            Text("Today · 32m · Teams")
                .font(.system(size: 7.5))
                .foregroundStyle(.black.opacity(0.45))
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(NookPalette.accent).frame(width: 150, height: 5)
                Capsule().fill(.black.opacity(0.16)).frame(width: 176, height: 5)
                Capsule().fill(.black.opacity(0.10)).frame(width: 120, height: 5)
            }
            .padding(.top, 2)
        }
        .padding(12)
        .frame(width: 214, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 16)
    }
}

/// A call window, so the step about system audio shows what it hears.
private struct StageMeetingWindow: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach([Color.red, .yellow, .green], id: \.self) { color in
                    Circle().fill(color.opacity(0.85)).frame(width: 5, height: 5)
                }
                Spacer()
            }
            .padding(.horizontal, 7)
            .frame(height: 13)
            HStack(spacing: 5) {
                ForEach(0..<2, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: index == 0
                                    ? [Color(red: 0.30, green: 0.36, blue: 0.55), Color(red: 0.18, green: 0.22, blue: 0.36)]
                                    : [Color(red: 0.42, green: 0.30, blue: 0.40), Color(red: 0.25, green: 0.18, blue: 0.26)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay {
                            Image(systemName: "person.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                }
            }
            .padding(6)
        }
        .frame(width: 210, height: 102)
        .background(Color(red: 0.13, green: 0.14, blue: 0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 14)
    }
}

/// A calendar reminder banner, as macOS shows one.
private struct StageCalendarBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: 13))
                .foregroundStyle(.red.opacity(0.9))
                .frame(width: 24, height: 24)
                .background(.white, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text("Design review")
                    .font(.system(size: 10, weight: .semibold))
                Text("10:00 – 10:30 · Teams")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(width: 190, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(16)
    }
}

/// A message being dictated into, character by character.
private struct StageMessageField: View {
    let reduceMotion: Bool
    @State private var started = Date()
    private static let message = "Running five minutes late, start without me."

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let elapsed = context.date.timeIntervalSince(started).truncatingRemainder(dividingBy: 4.2)
            let count = reduceMotion
                ? Self.message.count
                : min(Self.message.count, Int(max(0, elapsed - 0.4) * 16))
            HStack(spacing: 1) {
                Text(String(Self.message.prefix(count)))
                    .font(.system(size: 11))
                    .foregroundStyle(.black.opacity(0.85))
                    .lineLimit(1)
                RoundedRectangle(cornerRadius: 1)
                    .fill(NookPalette.accent)
                    .frame(width: 2, height: 13)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(count == Self.message.count ? NookPalette.accent : .gray.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .frame(width: 330, height: 34)
            .background(.white, in: Capsule())
            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 24)
    }
}

/// A small burst of lagoon light from the island, once, for the last step.
private struct CelebrationBurst: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fired = false

    var body: some View {
        ZStack {
            ForEach(0..<16, id: \.self) { index in
                let angle = Double(index) / 16 * .pi + .pi / 32
                Capsule()
                    .fill(index.isMultiple(of: 3) ? Color.white : NookPalette.accentHighlight)
                    .frame(width: 3, height: index.isMultiple(of: 2) ? 9 : 6)
                    .rotationEffect(.radians(angle + .pi / 2))
                    .offset(
                        x: fired ? cos(angle) * (90 + Double(index % 4) * 18) : 0,
                        y: fired ? sin(angle) * (60 + Double(index % 3) * 16) : 0
                    )
                    .opacity(fired ? 0 : 1)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.3).delay(0.35)) {
                fired = true
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// The system group box, for content set apart on a setup step.
    fileprivate func nookGroupBox() -> some View {
        GroupBox { self }
    }
}

/// A setting on a setup step, laid out like a grouped form row: title and
/// explanation on the leading edge, the switch on the trailing edge.
private struct WelcomeSwitchRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        GroupBox {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle(title, isOn: $isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityHint(detail)
            }
            .padding(6)
        }
    }
}
