import Foundation
import Testing
@testable import Nook

struct MarkdownCodecTests {
    @Test
    func updateFeedUsesThePublicReleaseRepository() {
        #expect(
            NookUpdateFeed.appcastURLString
                == "https://github.com/wrnsnng/nook-releases/releases/download/updates/appcast.xml"
        )
        #expect(
            NookUpdateFeed.archiveURLString(for: "1.4")
                == "https://github.com/wrnsnng/nook-releases/releases/download/v1.4/Nook-1.4.zip"
        )
    }

    @Test
    func updateSecurityConfigurationCannotDriftFromTheFeed() throws {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("project.yml")
        let project = try String(contentsOf: projectURL, encoding: .utf8)

        #expect(project.contains(NookUpdateFeed.appcastURLString))
        #expect(project.contains(NookUpdateFeed.publicEdKey))
        #expect(project.contains("SURequireSignedFeed: true"))
        #expect(project.contains("SUVerifyUpdateBeforeExtraction: true"))
    }

    @Test
    func roundTripsMeetingNote() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let note = MeetingNote(
            id: UUID(uuidString: "C417A77A-6D3D-42E0-A4E8-D96A715C4E65")!,
            title: "Product sync",
            startedAt: start,
            endedAt: start.addingTimeInterval(1_800),
            sourceApp: "Teams",
            summary: "The team agreed on the launch scope.",
            keyPoints: ["Beta starts next week"],
            decisions: ["Keep the onboarding short"],
            actionItems: ["Sam — publish the checklist by Friday"],
            personalNotes: "Ask Sam whether legal has reviewed the launch copy.",
            transcript: [
                TranscriptSegment(
                    startTime: 12,
                    duration: 3,
                    text: "Welcome everyone.",
                    source: .system
                ),
                TranscriptSegment(
                    startTime: 18,
                    duration: 2,
                    text: "Good to be here.",
                    source: .microphone
                )
            ]
        )

        let markdown = MarkdownCodec.encode(note)
        let decoded = try #require(MarkdownCodec.decode(markdown))

        #expect(decoded.id == note.id)
        #expect(decoded.title == note.title)
        #expect(decoded.sourceApp == "Teams")
        #expect(decoded.keyPoints == note.keyPoints)
        #expect(decoded.decisions == note.decisions)
        #expect(decoded.actionItems == note.actionItems)
        #expect(decoded.personalNotes == note.personalNotes)
        #expect(decoded.transcript.first?.text == "Welcome everyone.")
        #expect(decoded.transcript.first?.timestamp == "00:12")
        #expect(decoded.transcript.first?.source == .system)
        #expect(decoded.transcript.last?.source == .microphone)
        #expect(markdown.contains("**Meeting:** Welcome everyone."))
        #expect(markdown.contains("**You:** Good to be here."))
    }

    @Test
    func extractsCaseInsensitiveSections() {
        let markdown = """
        ## SUMMARY
        A compact summary.
        ## Action items
        - [ ] Finish the prototype
        """

        #expect(MarkdownCodec.section("Summary", in: markdown).contains("compact"))
    }

    @Test
    func notchCaptionsKeepRecentContextWhileSpeechIsInProgress() {
        let segments = (0..<6).map { index in
            TranscriptSegment(
                startTime: Double(index),
                duration: 1,
                text: "Final passage \(index)",
                source: index.isMultiple(of: 2) ? .system : .microphone
            )
        }
        let state = LiveTranscriptState(
            segments: segments,
            meetingPartial: "The sentence that is still arriving",
            microphonePartial: "",
            latestSource: .system,
            revision: 9
        )

        #expect(state.notchCaptionLines.count == 4)
        #expect(state.notchCaptionLines.first?.text == "Final passage 3")
        #expect(state.notchCaptionLines.last?.text == "The sentence that is still arriving")
        #expect(state.notchCaptionLines.last?.isPartial == true)
    }

    @Test
    func notchCaptionsKeepFiveFinalLinesWhenTheSpeakerPauses() {
        let segments = (0..<7).map { index in
            TranscriptSegment(
                startTime: Double(index),
                duration: 1,
                text: "Passage \(index)"
            )
        }
        let state = LiveTranscriptState(segments: segments)

        #expect(state.notchCaptionLines.count == 5)
        #expect(state.notchCaptionLines.first?.text == "Passage 2")
        #expect(state.notchCaptionLines.last?.text == "Passage 6")
    }

    @Test
    func compactRecordingUsesTheUltraSlimTopEdgeRail() {
        let size = NotchPanelMetrics.bodySize(
            for: .recording(title: "Design review", startedAt: .now),
            showsCaptions: false,
            panelMode: .transcript
        )

        #expect(size.width == 286)
        #expect(size.height == 30)
    }

    @Test
    func heuristicTitlesSkipMeetingChatterAndUseConversationContent() {
        let title = MeetingTitleGenerator.heuristicTitle(
            from: [
                "Meeting: Okay everyone, thanks for joining",
                "Meeting: The onboarding should explain privacy at the moment it matters",
            ],
            fallbackTitle: "Meeting — Wed 2:03 PM"
        )

        #expect(title == "The onboarding should explain privacy at the moment")
    }

    @Test
    @MainActor
    func blankNotesArePortableMarkdownWithoutAnEmptySummaryArtifact() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(
                "NookBlankNoteTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: directory) }

        let store = MarkdownStore()
        store.storageURL = directory
        let note = try store.createBlankNote()
        let markdown = store.rawMarkdown(for: note)
        let decoded = try #require(
            MarkdownCodec.decode(markdown, fileURL: note.fileURL)
        )

        #expect(decoded.summary.isEmpty)
        #expect(decoded.personalNotes.isEmpty)
        #expect(note.fileURL?.pathExtension == "md")
    }

    @Test
    @MainActor
    func personalNotesSaveIsVerifiedInTheMarkdownFile() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(
                "NookPersonalNotesTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: directory) }

        let store = MarkdownStore()
        store.storageURL = directory
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let original = try store.save(
            MeetingNote(
                title: "Notes persistence",
                startedAt: start,
                endedAt: start.addingTimeInterval(60),
                sourceApp: "Manual",
                summary: ""
            )
        )

        let saved = try store.updatePersonalNotes(
            "Send the accessibility follow-up.",
            for: original
        )
        let fileURL = try #require(saved.fileURL)
        let markdown = try String(
            contentsOf: fileURL,
            encoding: .utf8
        )
        let decoded = try #require(
            MarkdownCodec.decode(markdown, fileURL: fileURL)
        )

        #expect(
            MarkdownCodec.section("My notes", in: markdown)
                .contains("Send the accessibility follow-up.")
        )
        #expect(
            decoded.personalNotes
                == "Send the accessibility follow-up."
        )
    }

    @Test
    @MainActor
    func meetingWorkspaceRestoresItsLastPresentation() {
        let defaults = UserDefaults.standard
        let previousCaptions = defaults.object(forKey: "showLiveCaptions")
        let previousMode = defaults.object(forKey: "meetingPanelMode")
        defer {
            if let previousCaptions {
                defaults.set(previousCaptions, forKey: "showLiveCaptions")
            } else {
                defaults.removeObject(forKey: "showLiveCaptions")
            }
            if let previousMode {
                defaults.set(previousMode, forKey: "meetingPanelMode")
            } else {
                defaults.removeObject(forKey: "meetingPanelMode")
            }
        }

        defaults.set(false, forKey: "showLiveCaptions")
        defaults.set(
            MeetingPanelMode.summary.rawValue,
            forKey: "meetingPanelMode"
        )
        let coordinator = MeetingCoordinator(
            store: MarkdownStore(),
            detector: MeetingDetector()
        )

        #expect(coordinator.showLiveCaptions == false)
        #expect(coordinator.panelMode == .summary)

        coordinator.selectPanelMode(.notes)
        coordinator.setLiveNotesDetached(true)

        #expect(coordinator.liveNotesDetached)
        #expect(coordinator.panelMode == .transcript)

        coordinator.setLiveNotesDetached(false)
        #expect(!coordinator.liveNotesDetached)
    }

    @Test
    @MainActor
    func finishingAMeetingSignalsAuxiliaryWindowsBeforeProcessing() {
        let coordinator = MeetingCoordinator(
            store: MarkdownStore(),
            detector: MeetingDetector()
        )
        var didSignalStop = false
        coordinator.onRecordingStopped = {
            didSignalStop = true
        }
        coordinator.setPreviewState(
            phase: .recording(title: "Design review", startedAt: .now),
            elapsed: 42,
            liveTranscript: .empty,
            audioLevel: 0.2
        )

        coordinator.stopRecording()

        #expect(didSignalStop)
        #expect(coordinator.phase == .processing(.preparing))
    }

    @Test
    @MainActor
    func storeDoesNotOverwriteMeetingsWithMatchingTitlesAndMinutes() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("NookStoreTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let store = MarkdownStore()
        store.storageURL = directory
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let first = MeetingNote(
            title: "Weekly sync",
            startedAt: start,
            endedAt: start.addingTimeInterval(60),
            sourceApp: "Teams",
            summary: "First meeting"
        )
        let second = MeetingNote(
            title: "Weekly sync",
            startedAt: start.addingTimeInterval(10),
            endedAt: start.addingTimeInterval(70),
            sourceApp: "Teams",
            summary: "Second meeting"
        )

        let firstSaved = try store.save(first)
        let secondSaved = try store.save(second)

        #expect(firstSaved.fileURL != secondSaved.fileURL)
        #expect(store.notes.count == 2)
        #expect(Set(store.notes.map(\.summary)) == ["First meeting", "Second meeting"])
    }

    @Test
    func transcriptAssemblerTurnsRapidFragmentsIntoReadablePassages() {
        let segments = [
            TranscriptSegment(
                startTime: 0,
                duration: 0.8,
                text: "Hello this is",
                source: .system
            ),
            TranscriptSegment(
                startTime: 0.9,
                duration: 0.2,
                text: "the",
                source: .system
            ),
            TranscriptSegment(
                startTime: 1.6,
                duration: 0.3,
                text: "live",
                source: .system
            ),
            TranscriptSegment(
                startTime: 1.6,
                duration: 0.5,
                text: "transcript.",
                source: .system
            ),
        ]

        let passages = TranscriptAssembler.coalesce(segments)

        #expect(passages.count == 1)
        #expect(passages[0].text == "Hello this is the live transcript.")
        #expect(passages[0].startTime == 0)
        #expect(passages[0].duration >= 2.1)
    }

    @Test
    func transcriptAssemblerPreservesSpeakerChangesAndNaturalBreaks() {
        let passages = TranscriptAssembler.coalesce([
            TranscriptSegment(
                startTime: 0,
                duration: 2,
                text: "This is a complete opening thought.",
                source: .system
            ),
            TranscriptSegment(
                startTime: 2.2,
                duration: 1,
                text: "A new thought follows.",
                source: .system
            ),
            TranscriptSegment(
                startTime: 3.3,
                duration: 1,
                text: "I agree.",
                source: .microphone
            ),
        ])

        #expect(passages.count == 3)
        #expect(passages.map(\.source) == [.system, .system, .microphone])
    }

    @Test
    func placeholderBulletsAreNotPresentedAsMeetingContent() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let markdown = MarkdownCodec.encode(
            MeetingNote(
                title: "Placeholder test",
                startedAt: start,
                endedAt: start.addingTimeInterval(60),
                sourceApp: "Manual",
                summary: "A summary."
            )
        )
        let decoded = try #require(MarkdownCodec.decode(markdown))

        #expect(decoded.keyPoints.isEmpty)
        #expect(decoded.decisions.isEmpty)
        #expect(decoded.actionItems.isEmpty)
    }

    @Test
    func permissionSettingsRouteToTheMatchingPrivacyPane() {
        #expect(
            NookPermission.screenRecording.settingsURL?.absoluteString
                .hasSuffix("Privacy_ScreenCapture") == true
        )
        #expect(
            NookPermission.microphone.settingsURL?.absoluteString
                .hasSuffix("Privacy_Microphone") == true
        )
        #expect(
            NookPermission.speechRecognition.settingsURL?.absoluteString
                .hasSuffix("Privacy_SpeechRecognition") == true
        )
    }

    @Test
    func librarySearchMatchesEveryTermAcrossTranscriptAndMetadata() {
        let matching = MeetingNote(
            title: "Product review",
            startedAt: .now,
            endedAt: .now,
            sourceApp: "Teams",
            summary: "Discussed launch readiness.",
            personalNotes: "Follow up with legal about the launch copy.",
            transcript: [
                TranscriptSegment(
                    startTime: 0,
                    duration: 1,
                    text: "Rich will prepare the checklist."
                )
            ]
        )
        let unrelated = MeetingNote(
            title: "Design critique",
            startedAt: .now,
            endedAt: .now,
            sourceApp: "Zoom",
            summary: "Reviewed the visual system."
        )

        let ids = LibrarySearchController.matches(
            query: "Rich Teams legal",
            notes: [matching, unrelated]
        )

        #expect(ids == Set([matching.id]))
    }

    @Test
    @MainActor
    func storeSurfacesInvalidMarkdownFiles() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("NookInvalidFileTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        try "# Missing frontmatter".write(
            to: directory.appendingPathComponent("broken.md"),
            atomically: true,
            encoding: .utf8
        )

        let store = MarkdownStore()
        store.storageURL = directory
        store.reload()
        for _ in 0..<100 where store.isLoading {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(store.notes.isEmpty)
        #expect(store.loadIssues.count == 1)
        #expect(store.lastError?.contains("couldn’t be loaded") == true)
    }

    @Test
    @MainActor
    func markdownDraftCanBeRecoveredOrDiscardedWithoutLosingText() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("NookDraftTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let store = MarkdownStore()
        store.storageURL = directory
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let note = try store.save(
            MeetingNote(
                title: "Draft safety",
                startedAt: start,
                endedAt: start.addingTimeInterval(60),
                sourceApp: "Manual",
                summary: "Original"
            )
        )
        let draft = MarkdownDraftController()
        draft.prepare(for: note, store: store)
        draft.rawMarkdown += "\nUnsaved thought"

        #expect(draft.hasChanges)
        #expect(draft.rawMarkdown.contains("Unsaved thought"))

        draft.discardChanges()

        #expect(!draft.hasChanges)
        #expect(!draft.rawMarkdown.contains("Unsaved thought"))
    }

    @Test
    @MainActor
    func markdownDraftRefreshesAfterPersonalNotesAreSaved() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("NookDraftRefreshTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let store = MarkdownStore()
        store.storageURL = directory
        let note = try store.save(
            MeetingNote(
                title: "Refresh",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                endedAt: Date(timeIntervalSince1970: 1_700_000_000),
                sourceApp: "Personal",
                summary: ""
            )
        )
        let draft = MarkdownDraftController()
        draft.prepare(for: note, store: store)
        #expect(!draft.rawMarkdown.contains("Verified personal note"))

        let saved = try store.updatePersonalNotes(
            "Verified personal note",
            for: note
        )
        draft.refresh(for: saved, store: store)

        #expect(draft.rawMarkdown.contains("Verified personal note"))
        #expect(!draft.hasChanges)
    }

    @Test
    func groundingRemovesInventedActionsAndDecisions() {
        let proposed = MeetingInsights(
            title: "Casual conversation",
            summary: "The group chatted.",
            keyPoints: ["Potatoes came up."],
            decisions: ["Buy more potatoes."],
            actionItems: ["Rich — investigate potatoes."]
        )
        let transcript = [
            TranscriptSegment(
                startTime: 0,
                duration: 3,
                text: "I enjoy potatoes because they are versatile."
            )
        ]

        let grounded = MeetingInsightGrounder.ground(proposed, in: transcript)

        #expect(grounded.decisions.isEmpty)
        #expect(grounded.actionItems.isEmpty)
    }

    @Test
    func groundingKeepsStructuredItemsWhenCommitmentWasSpoken() {
        let proposed = MeetingInsights(
            title: "Launch review",
            summary: "The team prepared launch.",
            keyPoints: [],
            decisions: ["Use the shorter onboarding."],
            actionItems: ["Sam — publish the checklist by Friday."]
        )
        let transcript = [
            TranscriptSegment(
                startTime: 0,
                duration: 4,
                text: "We decided to use the shorter onboarding."
            ),
            TranscriptSegment(
                startTime: 5,
                duration: 4,
                text: "Sam, can you publish the checklist by Friday?"
            ),
        ]

        let grounded = MeetingInsightGrounder.ground(proposed, in: transcript)

        #expect(grounded.decisions == proposed.decisions)
        #expect(grounded.actionItems == proposed.actionItems)
    }

    @Test
    @MainActor
    func openingAnotherNoteCannotReplaceAnUnsavedDraft() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("NookDraftRestoreTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let store = MarkdownStore()
        store.storageURL = directory
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try store.save(
            MeetingNote(
                title: "First",
                startedAt: start,
                endedAt: start.addingTimeInterval(60),
                sourceApp: "Manual",
                summary: "First summary"
            )
        )
        let second = try store.save(
            MeetingNote(
                title: "Second",
                startedAt: start.addingTimeInterval(120),
                endedAt: start.addingTimeInterval(180),
                sourceApp: "Manual",
                summary: "Second summary"
            )
        )
        let draft = MarkdownDraftController()
        draft.prepare(for: first, store: store)
        draft.rawMarkdown += "\nProtected edit"

        draft.prepare(for: second, store: store)

        #expect(draft.noteID == first.id)
        #expect(draft.rawMarkdown.contains("Protected edit"))
        #expect(draft.hasChanges)
    }
}
