import SwiftUI

/// Selecting emphasis only saves the choice. Generation is a separate action
/// so changing a menu never starts a model unexpectedly.
struct SummaryRecipeControl: View {
    @Binding var recipe: SummaryRecipe
    let isEnabled: Bool
    let regenerate: () -> Void

    /// A pull-down beside the section title, the way Photos and Notes tuck
    /// view options away. Choosing a recipe inside the menu only saves it;
    /// Regenerate is a separate item, so a selection never starts a model.
    var body: some View {
        Menu {
            Picker("Summary Recipe", selection: $recipe) {
                ForEach(SummaryRecipe.allCases) { option in Text(option.title).tag(option) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Regenerate Summary", action: regenerate)
        } label: {
            Text(recipe.title)
        }
        .menuStyle(.borderlessButton)
        // Tinted text, so the luminous accent rather than the fill colour.
        .tint(NookPalette.accent)
        .fixedSize()
        .disabled(!isEnabled)
        .help(recipe == .general
              ? "General keeps the usual balance. Choose a recipe for emphasis, then regenerate on this Mac."
              : recipe.guidance + " Choose Regenerate Summary to apply it on this Mac.")
        .accessibilityLabel("Summary recipe, \(recipe.title)")
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
