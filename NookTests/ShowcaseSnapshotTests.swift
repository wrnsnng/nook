import AppKit
import SwiftUI
import Testing
@testable import Nook

struct ShowcaseSnapshotTests {
    @Test
    @MainActor
    func rendersLibraryShowcaseWhenRequested() throws {
        guard
            let outputPath = ProcessInfo.processInfo.environment["NOOK_SNAPSHOT_PATH"],
            !outputPath.isEmpty
        else {
            return
        }

        let fileManager = FileManager.default
        let fixtureDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("NookShowcase-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? fileManager.removeItem(at: fixtureDirectory)
        }

        let store = MarkdownStore()
        store.storageURL = fixtureDirectory
        for note in Self.fixtures {
            try store.save(note)
        }

        let detector = MeetingDetector()
        let meeting = MeetingCoordinator(store: store, detector: detector)
        let recovery = RecordingRecovery(store: store)
        let content = LibraryView()
            .environmentObject(store)
            .environmentObject(meeting)
            .environmentObject(recovery)
            .frame(width: 1_220, height: 760)
            .preferredColorScheme(.dark)

        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: 1_220, height: 760)
        renderer.scale = 2

        let image = try #require(renderer.nsImage)
        let representation = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 2_440,
                pixelsHigh: 1_520,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        representation.size = image.size

        NSGraphicsContext.saveGraphicsState()
        let context = try #require(NSGraphicsContext(bitmapImageRep: representation))
        NSGraphicsContext.current = context
        image.draw(
            in: NSRect(origin: .zero, size: image.size),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let data = try #require(
            representation.representation(
                using: .png,
                properties: [:]
            )
        )
        try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }

    private static let fixtures: [MeetingNote] = {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let latestStart = calendar.date(byAdding: .minute, value: -48, to: now) ?? now
        let planningStart = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let researchStart = calendar.date(byAdding: .day, value: -3, to: now) ?? now

        return [
            MeetingNote(
                id: UUID(uuidString: "7AA62B57-3D97-471A-A312-FC2C21E75858")!,
                title: "A gentler first-run experience",
                startedAt: latestStart,
                endedAt: latestStart.addingTimeInterval(2_760),
                sourceApp: "Teams",
                summary: "The team aligned on a calmer onboarding that demonstrates value before asking for configuration. The first session should feel guided, private, and unmistakably native to the Mac.",
                keyPoints: [
                    "Begin with a short, useful sample instead of a permissions wall.",
                    "Explain local processing at the moment it matters, not as legal copy.",
                    "Keep the notch prompt compact until the user opts into recording."
                ],
                decisions: [
                    "Prototype the three-step onboarding for Friday’s review.",
                    "Use system permission sheets without recreating them in-app."
                ],
                actionItems: [
                    "Maya — refine the first-run copy by Thursday.",
                    "Leo — validate the permission sequence on a clean Mac.",
                    "Ana — prepare five usability sessions for next week."
                ],
                transcript: [
                    TranscriptSegment(
                        startTime: 4,
                        duration: 8,
                        text: "I want the first minute to feel like the product is already helping.",
                        source: .system
                    ),
                    TranscriptSegment(
                        startTime: 14,
                        duration: 7,
                        text: "Yes, and privacy should be visible without becoming the whole story.",
                        source: .microphone
                    )
                ]
            ),
            MeetingNote(
                id: UUID(uuidString: "32782918-5BA5-432C-B26C-120EBF1BA98B")!,
                title: "Summer launch planning",
                startedAt: planningStart,
                endedAt: planningStart.addingTimeInterval(3_180),
                sourceApp: "Zoom",
                summary: "Launch scope is stable and the remaining risk is documentation readiness.",
                keyPoints: ["Beta feedback is trending positive."],
                decisions: ["Keep the current launch date."],
                actionItems: ["Priya — publish the launch checklist."],
                transcript: []
            ),
            MeetingNote(
                id: UUID(uuidString: "F07DD55B-C878-4DCB-A8EC-8676A96DA912")!,
                title: "Research synthesis",
                startedAt: researchStart,
                endedAt: researchStart.addingTimeInterval(2_340),
                sourceApp: "Google Meet",
                summary: "People value confidence and retrieval more than exhaustive meeting detail.",
                keyPoints: ["Search should work across summaries and spoken words."],
                decisions: [],
                actionItems: ["Share the synthesis with the product group."],
                transcript: []
            )
        ]
    }()
}
