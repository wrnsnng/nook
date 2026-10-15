import Testing
@testable import Nook

/// Nook sits in the Dock and ⌘-Tab while one of its windows is open, and goes
/// back to the menu bar when the last one closes, whichever windows they are.
struct DockPresenceTests {
    private func window(
        visible: Bool = true, minimized: Bool = false, titled: Bool = true,
        panel: Bool = false, sheet: Bool = false
    ) -> DockPresence.Window {
        DockPresence.Window(
            isVisible: visible, isMiniaturized: minimized, isTitled: titled,
            isPanel: panel, isSheet: sheet
        )
    }

    @Test
    func anOpenWindowKeepsNookInTheDock() {
        #expect(DockPresence.wantsDock([window()]))
    }

    /// The notch, dictation indicator and quick-note pad are panels; the
    /// menu bar item's own window is untitled; none of them count.
    @Test
    func floatingPanelsAndTheMenuBarDoNotCount() {
        #expect(!DockPresence.wantsDock([]))
        #expect(!DockPresence.wantsDock([window(panel: true), window(titled: false)]))
        #expect(!DockPresence.wantsDock([window(visible: false)]))
        #expect(!DockPresence.wantsDock([window(sheet: true)]))
    }

    /// A minimized window can only come back through the Dock.
    @Test
    func aMinimizedWindowKeepsNookInTheDock() {
        #expect(DockPresence.wantsDock([window(visible: false, minimized: true)]))
    }

    /// Settings is a window like any other: it alone keeps Nook switchable,
    /// which the old role list, which never contained it, got wrong.
    @Test
    func settingsAloneStillCounts() {
        let settings = window()
        #expect(DockPresence.wantsDock([settings, window(panel: true)]))
    }
}
