import SwiftUI

/// Provenance stays visible while Retry runs; progress is a separate concern.
/// Text and the explicit action remain independent accessibility elements.
struct SummaryFallbackCard: View {
    let provenance: SummaryProvenance
    let isRunning: Bool
    let canRetry: Bool
    let retry: () -> Void

    /// A system group box: the standard container for a note that sits
    /// apart from the document without being an alert.
    var body: some View {
        GroupBox {
        VStack(alignment: .leading, spacing: 10) {
            Label(SummaryFallback.title(for: provenance), systemImage: "doc.text.magnifyingglass")
                .font(.headline)
            Text(SummaryFallback.detail(for: provenance)).font(.callout)
            Button(isRunning ? "Summary in Progress" : "Retry Summary", action: retry)
                .buttonStyle(.bordered)
                .disabled(isRunning || !canRetry)
                .help("Regenerate on this Mac from the saved transcript. Save or revert Markdown edits first.")
            if !canRetry, !isRunning {
                Text("Retry requires a saved transcript and no unsaved Markdown edits.").font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        }
        .accessibilityElement(children: .contain)
    }
}

/// The same provenance, carried by the lead surface itself.
///
/// On the Notes tab the write-up is already set apart under "Fallback
/// write-up". A second card above it saying the same thing made the page
/// open with two heavy blocks, so there the explanation is one quiet line
/// at the top of the lead, beside the only action it needs.
struct SummaryFallbackNotice: View {
    let provenance: SummaryProvenance
    let isRunning: Bool
    let canRetry: Bool
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(SummaryFallback.detail(for: provenance))
                    .font(NookType.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(SummaryFallback.title(for: provenance))
                    .accessibilityLabel(
                        "\(SummaryFallback.title(for: provenance)). \(SummaryFallback.detail(for: provenance))"
                    )
                Button(isRunning ? "Summary in Progress" : "Retry Summary", action: retry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(isRunning || !canRetry)
                    .help("Regenerate on this Mac from the saved transcript. Save or revert Markdown edits first.")
            }
            if !canRetry, !isRunning {
                Text("Retry requires a saved transcript and no unsaved Markdown edits.")
                    .font(NookType.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

#Preview("Transcript highlights") {
    SummaryFallbackCard(provenance: .transcriptHighlights, isRunning: false, canRetry: true, retry: {})
        .padding().frame(width: 360)
}

#Preview("Edited fallback, running") {
    SummaryFallbackCard(provenance: .editedFallback, isRunning: true, canRetry: false, retry: {})
        .padding().frame(width: 300)
}

#Preview("Lead notice") {
    SummaryFallbackNotice(provenance: .transcriptHighlights, isRunning: false, canRetry: true, retry: {})
        .padding().frame(width: 520)
}
