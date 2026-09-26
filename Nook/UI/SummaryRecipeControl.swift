import SwiftUI

/// Selecting emphasis only saves the choice. Generation is a separate action
/// so changing a menu never starts a model unexpectedly.
struct SummaryRecipeControl: View {
    @Binding var recipe: SummaryRecipe
    let isEnabled: Bool
    let regenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    recipePicker
                    Spacer(minLength: 8)
                    regenerateButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    recipePicker
                    regenerateButton
                }
            }
            .disabled(!isEnabled)
            Text(recipe == .general
                 ? "General keeps the usual balance. Select a recipe for emphasis, then regenerate on this Mac."
                 : recipe.guidance + " Select Regenerate Summary to apply it on this Mac.")
                .font(NookType.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }

    private var recipePicker: some View {
        Picker("Summary recipe", selection: $recipe) {
            ForEach(SummaryRecipe.allCases) { option in Text(option.title).tag(option) }
        }
        .pickerStyle(.menu)
        .fixedSize()
    }

    private var regenerateButton: some View {
        Button("Regenerate Summary", action: regenerate)
            .buttonStyle(.bordered)
            .fixedSize()
    }
}

#Preview("Selected recipe") {
    SummaryRecipeControl(recipe: .constant(.standup), isEnabled: true, regenerate: {})
        .padding().frame(width: 620)
}

#Preview("Recipe unavailable while busy") {
    SummaryRecipeControl(recipe: .constant(.interview), isEnabled: false, regenerate: {})
        .padding().frame(width: 620)
}
