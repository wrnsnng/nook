import SwiftUI

/// The prep surface for an approaching calendar event with history.
///
/// Entirely read-only and assembled from the user's own notes: what was
/// decided last time, the key points, every action item the series' notes
/// mention, and the sittings themselves. Quoting, never paraphrasing.
struct PrepBriefView: View {
    let brief: PrepBrief
    let onSelectNote: (MeetingNote.ID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                header
                SoftDivider()

                if !brief.lastDecisions.isEmpty {
                    listSection(
                        title: "Decided last time",
                        symbol: "checkmark.seal",
                        items: brief.lastDecisions
                    )
                }

                if !brief.lastKeyPoints.isEmpty {
                    listSection(
                        title: "Key points last time",
                        symbol: "sparkles",
                        items: brief.lastKeyPoints
                    )
                }

                if !brief.mentionedActions.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        NookSectionLabel(
                            title: "Actions mentioned across \(brief.sittings.count) sitting\(brief.sittings.count == 1 ? "" : "s")",
                            symbol: "square.and.pencil",
                            tint: NookPalette.accent
                        )
                        ForEach(
                            Array(brief.mentionedActions.enumerated()),
                            id: \.offset
                        ) { _, action in
                            Button {
                                onSelectNote(action.noteID)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 9) {
                                    Image(systemName: "arrow.turn.down.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(action.text)
                                            .font(NookType.transcript)
                                            .multilineTextAlignment(.leading)
                                            .textSelection(.enabled)
                                        Text(action.noteTitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if brief.sittings.count > 1 {
                    sittingsSection
                }
            }
            .padding(.horizontal, 42)
            .padding(.top, 32)
            .padding(.bottom, 24)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                "Prep for sitting \(brief.upcomingSittingNumber)",
                systemImage: "cup.and.saucer.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(NookPalette.accent)

            Text(brief.eventTitle)
                .font(NookType.title)
                .tracking(-0.45)
                .lineLimit(2)

            HStack(spacing: 15) {
                NookMetadataLabel(
                    title: brief.startDate.formatted(
                        date: .omitted,
                        time: .shortened
                    ),
                    symbol: "clock"
                )
                if let lastMetAt = brief.lastMetAt {
                    NookMetadataLabel(
                        title: "Last met "
                            + lastMetAt.formatted(
                                date: .abbreviated,
                                time: .omitted
                            ),
                        symbol: "calendar"
                    )
                }
                NookMetadataLabel(
                    title: brief.totalDuration.formattedAsHoursAndMinutes,
                    symbol: "hourglass"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func listSection(
        title: String,
        symbol: String,
        items: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            NookSectionLabel(title: title, symbol: symbol, tint: NookPalette.accent)
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(String(format: "%02d", index + 1))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(NookPalette.accent)
                        .frame(width: 24, alignment: .leading)
                    Text(item)
                        .font(NookType.transcript)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(title), item \(index + 1): \(item)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sittingsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            NookSectionLabel(
                title: "Earlier sittings",
                symbol: "clock.arrow.circlepath",
                tint: NookPalette.accent
            )
            ForEach(brief.sittings.prefix(8)) { sitting in
                Button {
                    onSelectNote(sitting.id)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sitting.title)
                                .lineLimit(1)
                            Text(
                                sitting.startedAt.formatted(
                                    date: .abbreviated,
                                    time: .shortened
                                )
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(sitting.durationLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if brief.sittings.count > 8 {
                Text("\(brief.sittings.count - 8) more in your library")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension TimeInterval {
    /// Compact hour-and-minute text; zero renders honestly as nothing held.
    var formattedAsHoursAndMinutes: String {
        let minutes = Int(self) / 60
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m total"
        }
        return "\(max(1, minutes))m total"
    }
}

/// The sidebar's quiet pointer at an upcoming event with history.
struct PrepCard: View {
    let brief: PrepBrief
    let isOpen: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 9) {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isOpen ? Color.white : NookPalette.accent)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(brief.eventTitle)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(
                            isOpen ? Color.white.opacity(0.85) : .secondary
                        )
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isOpen ? NookPalette.accent : NookPalette.accent.opacity(0.10)
                    )
            )
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
        return "Starts \(start) · sitting \(brief.upcomingSittingNumber)"
    }
}
