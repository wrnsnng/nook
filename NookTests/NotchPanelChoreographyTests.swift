import AppKit
import Foundation
import Testing
@testable import Nook

/// The real panel coordinator, driven the way the app drives it: a recording,
/// then Hide and Restore, which move the island beside the camera and back.
@MainActor
struct NotchPanelChoreographyTests {
    private func recordingPanel() async -> (MeetingCoordinator, NotchPanelCoordinator) {
        let meeting = MeetingCoordinator(store: MarkdownStore(), detector: MeetingDetector())
        meeting.showLiveCaptions = false
        let panel = NotchPanelCoordinator(meeting: meeting)
        // As AppModel wires them.
        meeting.onPresentationRequested = { [weak panel] in panel?.show() }
        meeting.onPanelDismissRequested = { [weak panel] in panel?.show() }
        await Task.yield()
        meeting.setPreviewState(
            phase: .recording(title: "Design review", startedAt: .now),
            elapsed: 30,
            liveTranscript: .empty,
            audioLevel: 0
        )
        panel.show()
        try? await Task.sleep(for: .seconds(1.2))
        return (meeting, panel)
    }

    private func settle() async {
        try? await Task.sleep(for: .seconds(1.4))
    }

    /// Hiding folds the island into the camera and reopens it as the small
    /// pill. Two layout requests arrive at once when hiding (the dismissal
    /// and the state change), and the second used to strand the fold: the
    /// island stayed inside the camera housing and could not be clicked.
    @Test
    func hidingEndsWithTheRecordingPillShowing() async {
        let (meeting, panel) = await recordingPanel()
        defer { panel.hide() }

        meeting.hideTopPanel()
        await settle()

        #expect(panel.panelIsVisible)
        #expect(!panel.geometry.isTucking)
        #expect(panel.geometry.revealProgress == 1)
        #expect(panel.panelFrame.width == NotchPanelMetrics.bodySize(for: .hiddenRecording).width)
    }

    /// Restoring reverses it: the pill folds away and the island comes back.
    @Test
    func restoringBringsTheIslandBack() async {
        let (meeting, panel) = await recordingPanel()
        defer { panel.hide() }

        meeting.hideTopPanel()
        await settle()
        meeting.restoreTopPanel()
        await settle()

        #expect(panel.panelIsVisible)
        #expect(!panel.geometry.isTucking)
        #expect(panel.geometry.revealProgress == 1)
        #expect(panel.panelFrame.width > NotchPanelMetrics.bodySize(for: .hiddenRecording).width)
    }
}
