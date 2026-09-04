import SwiftUI

/// Provenance stays visible while Retry runs; progress is a separate concern.
/// Text and the explicit action remain independent accessibility elements.
struct SummaryFallbackCard: View {
    let provenance: SummaryProvenance
    let isRunning: Bool
    let canRetry: Bool
    let retry: () -> Void

    var body: some View {
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
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
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
