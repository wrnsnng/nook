import SwiftUI

/// The prep surface for an approaching calendar event with history.
///
/// Entirely read-only and assembled from the user's own notes: what was
/// decided last time, the key points, every action item the series' notes
/// mention, and the sittings themselves. Quoting, never paraphrasing.
///
/// Laid out as a sibling of a note's page: the same readable column, title
/// and metadata line, section headings and list rows, so moving between the
/// brief and the notes it quotes does not change the reading rhythm.
struct PrepBriefView: View {
    let brief: PrepBrief
    let onSelectNote: (MeetingNote.ID) -> Void
    /// Starts a recording filed under this series. Absent wherever the view
    /// has no coordinator to ask, so the action is hidden rather than shown
    /// doing nothing.
    var onRecordSitting: (() -> Void)?

    /// A single sitting is already one click away through Open Last Notes,
    /// so the list only earns its place once there is a history to choose from.
    private static let visibleSittings = 8

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 38) {
                header

                if !brief.lastKeyPoints.isEmpty {
                    PrepSection(title: "Key points last time") {
                        VStack(alignment: .leading, spacing: 17) {
                            ForEach(Array(brief.lastKeyPoints.enumerated()), id: \.offset) { index, item in
                                HStack(alignment: .firstTextBaseline, spacing: 14) {
                                    NookBullet()
                                    quotedText(item)
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("Key point \(index + 1): \(item)")
                            }
                        }
                    }
                }

                if !brief.lastDecisions.isEmpty {
                    PrepSection(title: "Decisions last time") {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(Array(brief.lastDecisions.enumerated()), id: \.offset) { index, item in
                                // The note page's decision marker: an arrow,
                                // not a tick, so a decision never reads as a
                                // task somebody completed.
                                HStack(alignment: .top, spacing: 13) {
                                    Image(systemName: "arrow.turn.down.right")
                                        .font(NookType.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 20, height: 20)
                                        .accessibilityHidden(true)
                                    quotedText(item)
                                        .padding(.top, 1)
                                }
                                .padding(.vertical, 2)
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("Decision \(index + 1): \(item)")
                            }
                        }
                    }
                }

                if !brief.mentionedActions.isEmpty {
                    PrepSection(
                        title: "Actions mentioned across \(brief.sittings.count) sitting\(brief.sittings.count == 1 ? "" : "s")"
                    ) {
                        VStack(alignment: .leading, spacing: 0) {
                            let actions = Array(brief.mentionedActions.enumerated())
                            ForEach(actions, id: \.offset) { index, action in
                                actionRow(action)
                                if index < actions.count - 1 {
                                    Divider().padding(.leading, 24)
                                }
                            }
                        }
                        // The rows carry their own padding for the hover
                        // wash; without this the first sits a step lower
                        // under its heading than any list on a note's page.
                        .padding(.top, -8)
                    }
                }

                if brief.sittings.count > 1 {
                    PrepSection(title: "Earlier sittings") {
                        VStack(alignment: .leading, spacing: 0) {
                            let shown = Array(brief.sittings.prefix(Self.visibleSittings))
                            ForEach(Array(shown.enumerated()), id: \.element.libraryIdentity) { index, sitting in
                                sittingRow(sitting)
                                if index < shown.count - 1 {
                                    Divider()
                                }
                            }
                            if brief.sittings.count > Self.visibleSittings {
                                Text("\(brief.sittings.count - Self.visibleSittings) more in your library")
                                    .font(NookType.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 10)
                            }
                        }
                        .padding(.top, -8)
                    }
                }
            }
            .padding(.top, 28)
            .padding(.bottom, 36)
            .nookReadableColumn()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(brief.eventTitle)
                .font(NookType.title)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)

            // One quiet line with middle dots, as a note's page writes its
            // details. What the page is for and how often this has happened
            // are both context, so neither gets a label of its own.
            Text(PrepBriefCopy.metadata(for: brief).joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)

            if brief.omittedNoteCount > 0 {
                Label(LibraryNoteAggregation.omissionMessage, systemImage: "exclamationmark.triangle")
                    .font(NookType.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            headerActions
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The two things a person actually does from here: start this sitting,
    /// or reread the last one. Recording is what the page leads to, so it is
    /// the prominent one.
    @ViewBuilder
    private var headerActions: some View {
        let lastSitting = brief.sittings.first
        if onRecordSitting != nil || lastSitting != nil {
            HStack(spacing: NookSpacing.small) {
                if let onRecordSitting {
                    Button("Record This Sitting", action: onRecordSitting)
                        .buttonStyle(.borderedProminent)
                        .help("Start recording and file it under this meeting")
                }

                if let lastSitting {
                    Button("Open Last Notes") {
                        onSelectNote(lastSitting.id)
                    }
                    .buttonStyle(.bordered)
                    .help("Open the note from \(lastSitting.title)")
                }
            }
        }
    }

    // MARK: - Rows

    private func quotedText(_ text: String) -> some View {
        Text(text)
            .font(NookType.transcript)
            .lineSpacing(4)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Read-only: whether an item is finished lives in its own file, so the
    /// row names the item and where it was written rather than offering a
    /// tick it cannot honestly show.
    private func actionRow(_ action: PrepBrief.ActionItemRef) -> some View {
        let parsed = ActionItemOwner.parse(action.text)
        let source = [parsed.owner, action.noteTitle]
            .compactMap { $0 }
            .joined(separator: " · ")
        return Button {
            onSelectNote(action.noteID)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                NookBullet()
                VStack(alignment: .leading, spacing: 3) {
                    Text(parsed.owner == nil ? action.text : parsed.displayTask)
                        .font(NookType.transcript)
                        .lineSpacing(4)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)
                    Text(source)
                        .font(NookType.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(NookType.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 10)
        }
        .buttonStyle(NookLinkRowButtonStyle())
        .help("Open \(action.noteTitle)")
        .accessibilityLabel("\(action.text), from \(action.noteTitle)")
        .accessibilityHint("Opens the note this action came from")
    }

    private func sittingRow(_ sitting: MeetingNote) -> some View {
        Button {
            onSelectNote(sitting.id)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(sitting.title)
                        .font(NookType.transcript)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(sitting.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(NookType.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 12)
                Text(sitting.durationLabel)
                    .font(NookType.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(NookType.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 10)
        }
        .buttonStyle(NookLinkRowButtonStyle())
        .help("Open \(sitting.title)")
        .accessibilityHint("Opens the note from this sitting")
    }
}

/// A section of the brief, headed exactly as a note's page heads its own.
private struct PrepSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            NookSectionLabel(title: title, symbol: "text.alignleft", tint: NookPalette.accent)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row that opens a note: a list row rather than a bordered button, with
/// the wash Finder and Mail give a row under the pointer and a focus ring for
/// keyboard users. The wash reaches a little past the column so the row's
/// words stay on the same edge as the text above and below it.
struct NookLinkRowButtonStyle: ButtonStyle {
    var bleed: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        NookLinkRow(configuration: configuration, bleed: bleed)
    }

    private struct NookLinkRow: View {
        let configuration: ButtonStyleConfiguration
        let bleed: CGFloat
        @State private var isHovering = false
        @Environment(\.isFocused) private var isFocused
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: NookRadius.control, style: .continuous)
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background {
                    shape
                        .fill(.primary.opacity(configuration.isPressed ? 0.09 : isHovering ? 0.05 : 0))
                        .padding(.horizontal, -bleed)
                }
                .overlay {
                    shape
                        .stroke(NookPalette.accent.opacity(isFocused ? 0.85 : 0), lineWidth: 1.5)
                        .padding(.horizontal, -bleed)
                }
                .opacity(isEnabled ? 1 : 0.42)
                .onHover { isHovering = $0 }
                .animation(reduceMotion ? nil : NookMotion.quick, value: isHovering)
        }
    }
}

/// The prep brief's plain-language framing of a series' history.
///
/// Kept out of the view so the wording is testable: "sitting 2" was Nook's
/// bookkeeping leaking into the page, and the replacement has to read as a
/// sentence at every count.
enum PrepBriefCopy {
    static func history(
        sittings: Int,
        totalDuration: TimeInterval
    ) -> String {
        guard sittings > 0 else { return "You have not met before." }
        // A sitting shorter than a minute still happened; "0m total" reads as
        // a bug rather than as a very short meeting.
        let held = NookElapsedTime.minutes(
            totalDuration,
            atLeastAMinute: true
        )
        return "You have met \(times(sittings)) before, \(held) total"
    }

    /// The brief's metadata line, read as a note's page reads its own: when
    /// it starts, what the page is for, and the history in a few words.
    /// "Before this meeting" used to sit above the title as a label; it is
    /// context, so it belongs with the rest of the context.
    static func metadata(for brief: PrepBrief) -> [String] {
        var parts = [
            "Starts " + brief.startDate.formatted(date: .omitted, time: .shortened),
            "Before this meeting",
        ]
        if brief.sittings.isEmpty {
            if brief.omittedNoteCount > 0 {
                parts.append("Earlier notes need review before they can be included")
            }
            return parts
        }
        let held = NookElapsedTime.minutes(
            brief.totalDuration,
            atLeastAMinute: true
        )
        parts.append("Met \(times(brief.sittings.count)) before, \(held) total")
        if let lastMetAt = brief.lastMetAt {
            parts.append("Last met " + lastMetAt.formatted(date: .abbreviated, time: .omitted))
        }
        return parts
    }

    static func times(_ count: Int) -> String {
        switch count {
        case 1: "once"
        case 2: "twice"
        default: "\(count) times"
        }
    }
}

/// The sidebar's quiet pointer at an upcoming event with history.
struct PrepCard: View {
    let brief: PrepBrief
    let isOpen: Bool
    let onOpen: () -> Void

    /// An ordinary sidebar row; the list's own selection shows when the
    /// brief is open, as it does for every note below it.
    var body: some View {
        Button(action: onOpen) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(brief.eventTitle)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: "calendar")
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open the prep brief")
        .accessibilityLabel(
            "Prep brief for \(brief.eventTitle)"
        )
        .accessibilityHint("Opens notes from earlier sittings of this meeting")
    }

    private var subtitle: String {
        let start = brief.startDate.formatted(date: .omitted, time: .shortened)
        if brief.sittings.isEmpty && brief.omittedNoteCount > 0 {
            return "Starts \(start) · review copied notes"
        }
        return "Starts \(start) · met \(PrepBriefCopy.times(brief.sittings.count))"
    }
}
