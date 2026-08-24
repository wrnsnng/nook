import Foundation
import Speech
import Testing
@testable import Nook

struct MarkdownCodecTests {
    @Test
    func frontmatterRoundTripsEscapedCharacters() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let note = MeetingNote(
            title: "Path C:\\Meetings — \"Planning\"\nFollow-up",
            startedAt: start,
            endedAt: start.addingTimeInterval(60),
            sourceApp: "Browser\\Preview\tApp",
            summary: "A portable note."
        )

        let markdown = MarkdownCodec.encode(note)
        let decoded = try #require(MarkdownCodec.decode(markdown))

        #expect(decoded.title == note.title)
        #expect(decoded.sourceApp == note.sourceApp)
        #expect(markdown.contains("# Path C:\\Meetings — \"Planning\" Follow-up"))
    }

    @Test
    @MainActor
    func majorMeetingProvidersDetectAndEndWithoutAWindowTitleChange() throws {
        let fixtures: [(owner: String, title: String, appName: String)] = [
            (
                "Microsoft Teams",
                "Meeting with Taylor Rivera | Microsoft Teams",
                "Teams"
            ),
            ("zoom.us", "Weekly product sync", "Zoom"),
            ("Google Chrome", "Meet - abc-defg-hij", "Google Meet"),
            ("Safari", "Meet — abc-defg-hij", "Google Meet"),
            ("Microsoft Edge", "Google Meet", "Google Meet"),
            ("Firefox", "Meet – abc-defg-hij", "Google Meet"),
            ("Webex", "Taylor's Personal Room", "Webex"),
            ("FaceTime", "Taylor Rivera", "FaceTime")
        ]

        for fixture in fixtures {
            let detection = try #require(
                MeetingDetector.detectionForTesting(
                    owner: fixture.owner,
                    title: fixture.title,
                    audioActivity: .active
                )
            )
            #expect(detection.appName == fixture.appName)

            let detector = MeetingDetector()
            var endCount = 0
            detector.onMeetingEnded = { endCount += 1 }
            detector.acceptForTesting(
                detection,
                audioActivity: .active
            )
            detector.acceptForTesting(
                detection,
                audioActivity: .active
            )
            #expect(detector.currentDetection == detection)

            for _ in 0..<5 {
                detector.acceptForTesting(
                    detection,
                    audioActivity: .inactive
                )
            }

            #expect(detector.currentDetection == nil)
            #expect(endCount == 1)

            detector.acceptForTesting(
                detection,
                audioActivity: .inactive
            )
            detector.acceptForTesting(
                detection,
                audioActivity: .inactive
            )
            #expect(detector.currentDetection == nil)
        }
    }

    @Test
    @MainActor
    func nativeMeetingAppsNeedAudioWhenTheirTitleIsAmbiguous() {
        let ambiguousWindows = [
            ("zoom.us", "Weekly product sync"),
            ("Webex", "Taylor's Personal Room"),
            ("FaceTime", "Taylor Rivera")
        ]

        for window in ambiguousWindows {
            #expect(
                MeetingDetector.detectionForTesting(
                    owner: window.0,
                    title: window.1,
                    audioActivity: .inactive
                ) == nil
            )
            #expect(
                MeetingDetector.detectionForTesting(
                    owner: window.0,
                    title: window.1,
                    audioActivity: .active
                ) != nil
            )
        }

        #expect(
            MeetingDetector.detectionForTesting(
                owner: "FaceTime",
                title: "FaceTime",
                audioActivity: .inactive
            ) == nil
        )
        #expect(
            MeetingDetector.detectionForTesting(
                owner: "Google Chrome",
                title: "YouTube",
                audioActivity: .active
            ) == nil
        )
        #expect(
            MeetingDetector.detectionForTesting(
                owner: "Safari",
                title: "Google Meet",
                audioActivity: .inactive
            ) == nil
        )
    }

    @Test
    @MainActor
    func staleStrongMeetingWindowExpiresEvenWithoutObservedAudio() throws {
        let detection = try #require(
            MeetingDetector.detectionForTesting(
                owner: "Microsoft Teams",
                title: "Meeting with Taylor Rivera | Microsoft Teams",
                audioActivity: .inactive
            )
        )
        let detector = MeetingDetector()

        detector.acceptForTesting(
            detection,
            audioActivity: .inactive
        )
        detector.acceptForTesting(
            detection,
            audioActivity: .inactive
        )
        #expect(detector.currentDetection == detection)

        for _ in 0..<5 {
            detector.acceptForTesting(
                detection,
                audioActivity: .inactive
            )
        }
        #expect(detector.currentDetection == nil)

        detector.acceptForTesting(
            detection,
            audioActivity: .inactive
        )
        detector.acceptForTesting(
            detection,
            audioActivity: .inactive
        )
        #expect(detector.currentDetection == nil)
    }

    @Test
    @MainActor
    func providerAudioProfilesCoverNativeAppsAndMajorBrowsers() {
        let fixtures: [
            (
                owner: String,
                title: String,
                processIdentity: String
            )
        ] = [
            (
                "Microsoft Teams",
                "Teams meeting",
                "Microsoft Teams ModuleHost com.microsoft.teams2.modulehost"
            ),
            ("zoom.us", "Zoom Meeting", "zoom.us us.zoom.xos"),
            (
                "Google Chrome",
                "Meet - abc-defg-hij",
                "Google Chrome Helper com.google.Chrome.helper"
            ),
            (
                "Safari",
                "Google Meet",
                "com.apple.WebKit.WebContent"
            ),
            (
                "Microsoft Edge",
                "Google Meet",
                "Microsoft Edge Helper com.microsoft.edgemac.helper"
            ),
            (
                "Firefox",
                "Google Meet",
                "FirefoxCP org.mozilla.firefox"
            ),
            (
                "Webex",
                "Webex Meeting",
                "Webex com.cisco.webex2"
            ),
            (
                "FaceTime",
                "FaceTime call",
                "FaceTime com.apple.FaceTime"
            )
        ]

        for fixture in fixtures {
            #expect(
                MeetingDetector.audioIdentityMatchesForTesting(
                    owner: fixture.owner,
                    title: fixture.title,
                    processIdentity: fixture.processIdentity
                )
            )
        }
    }

    @Test
    @MainActor
    func detectedMeetingEndsWhenTeamsAudioStopsButItsWindowRemains() {
        let detector = MeetingDetector()
        let meeting = DetectedMeeting(
            appName: "Teams",
            windowTitle: "Meeting with Taylor Rivera | Microsoft Teams"
        )
        var startedMeeting: DetectedMeeting?
        var endCount = 0
        detector.onMeetingStarted = { startedMeeting = $0 }
        detector.onMeetingEnded = { endCount += 1 }

        detector.acceptForTesting(meeting, audioActivity: .active)
        detector.acceptForTesting(meeting, audioActivity: .active)

        #expect(detector.currentDetection == meeting)
        #expect(startedMeeting == meeting)

        for _ in 0..<4 {
            detector.acceptForTesting(meeting, audioActivity: .inactive)
        }
        #expect(detector.currentDetection == meeting)
        #expect(endCount == 0)

        detector.acceptForTesting(meeting, audioActivity: .inactive)

        #expect(detector.currentDetection == nil)
        #expect(endCount == 1)
    }

    @Test
    @MainActor
    func anIgnoredMeetingCanBeDetectedAgainAfterItsAudioEnds() {
        let detector = MeetingDetector()
        let coordinator = MeetingCoordinator(
            store: MarkdownStore(),
            detector: detector
        )
        let meeting = DetectedMeeting(
            appName: "Teams",
            windowTitle: "Design review | Microsoft Teams"
        )

        detector.acceptForTesting(meeting, audioActivity: .active)
        detector.acceptForTesting(meeting, audioActivity: .active)
        #expect(coordinator.phase == .detected(meeting))

        coordinator.dismissPrompt()
        #expect(coordinator.phase == .idle)

        for _ in 0..<5 {
            detector.acceptForTesting(meeting, audioActivity: .inactive)
        }
        #expect(detector.currentDetection == nil)
        #expect(coordinator.phase == .idle)

        detector.acceptForTesting(meeting, audioActivity: .inactive)
        detector.acceptForTesting(meeting, audioActivity: .inactive)
        #expect(detector.currentDetection == nil)
        #expect(coordinator.phase == .idle)

        detector.acceptForTesting(meeting, audioActivity: .active)
        detector.acceptForTesting(meeting, audioActivity: .active)
        #expect(coordinator.phase == .detected(meeting))
    }

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
        #expect(project.contains("SUEnableAutomaticChecks: true"))
        #expect(project.contains("SURequireSignedFeed: true"))
        #expect(project.contains("SUVerifyUpdateBeforeExtraction: true"))
    }

    @Test
    func applicationBundleShipsOnlyTheCobaltBrandIcon() {
        #expect(
            Bundle.main.url(
                forResource: "NookIconSource-Cobalt",
                withExtension: "png"
            ) != nil
        )
        #expect(
            Bundle.main.url(
                forResource: "NookIconSource",
                withExtension: "png"
            ) == nil
        )
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

        #expect(size.width == 316)
        // Tall enough for 30pt controls, the app's own hit-target floor.
        #expect(size.height == 42)
    }

    @Test
    func hiddenRecordingKeepsARecoverableCameraEdgeIndicator() {
        let size = NotchPanelMetrics.bodySize(
            for: .recording(title: "Design review", startedAt: .now),
            showsCaptions: false,
            panelMode: .transcript,
            isHidden: true
        )

        #expect(size.width == 86)
        #expect(size.height == 0)
    }

    @Test
    func detectedMeetingPromptStaysGlanceablyCompact() {
        let size = NotchPanelMetrics.bodySize(
            for: .detected(
                DetectedMeeting(
                    appName: "Teams",
                    windowTitle: "Design review"
                )
            ),
            showsCaptions: true,
            panelMode: .transcript
        )

        #expect(size.width == 360)
        #expect(size.height == 48)
    }

    /// The prompt used to disappear after eight seconds, which answered it on
    /// the user's behalf: the meeting went unrecorded and nothing was left to
    /// say Nook had ever offered. It now shrinks instead.
    @Test
    func aPromptThatRanOutOfTimeShrinksRatherThanDisappearing() {
        let detection = DetectedMeeting(
            appName: "Teams",
            windowTitle: "Design review"
        )
        let expanded = NotchPanelMetrics.bodySize(
            for: .detected(detection),
            showsCaptions: true,
            panelMode: .transcript
        )
        let compact = NotchPanelMetrics.bodySize(
            for: .detected(detection),
            showsCaptions: true,
            panelMode: .transcript,
            detectionPromptIsCompact: true
        )

        #expect(compact.width < expanded.width)
        #expect(compact.width > 0)
        // Tall enough for the 30pt Record control, the app's hit-target floor.
        #expect(compact.height >= 42)
    }

    /// Long enough to finish the sentence someone was saying when it appeared.
    @Test
    func theConsentPromptStaysWholeLongEnoughToBeAnswered() {
        #expect(DetectionPromptPolicy.state(afterVisibleFor: 8) == .expanded)
        #expect(DetectionPromptPolicy.state(afterVisibleFor: 59) == .expanded)
        #expect(DetectionPromptPolicy.state(afterVisibleFor: 60) == .compact)
        #expect(DetectionPromptPolicy.state(afterVisibleFor: 600) == .compact)
    }

    /// Detection fires while someone is joining a meeting. Activating Nook
    /// over that window takes the front from their camera and microphone
    /// controls, for a prompt they did not ask for.
    @Test
    func theConsentPromptOnlyTakesKeyFocusWhenNookIsAlreadyInFront() {
        #expect(DetectionPromptPolicy.takesKeyFocus(applicationIsActive: true))
        #expect(!DetectionPromptPolicy.takesKeyFocus(applicationIsActive: false))
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
    func generatedMeetingTitleReplacesTheTimestampFallback() {
        let title = MeetingTitleGenerator.resolvedTitle(
            proposedTitle: "Meeting — Thu 2:14 PM",
            summary: "The team agreed to simplify Nook’s top panel and make recording easier to spot.",
            keyPoints: ["Simplify the top panel recording controls"],
            transcript: [],
            fallbackTitle: "Meeting — Thu 2:14 PM"
        )

        #expect(title == "Simplify the top panel recording controls")
    }

    @Test
    func generatedMeetingTitlePreservesASpecificSubject() {
        let title = MeetingTitleGenerator.resolvedTitle(
            proposedTitle: "Nook top panel design review",
            summary: "The team reviewed the recording workspace.",
            keyPoints: [],
            transcript: [],
            fallbackTitle: "Meeting — Thu 2:14 PM"
        )

        #expect(title == "Nook top panel design review")
    }

    @Test
    func generatedMeetingTitleCanNaturallyEndInMeeting() {
        let title = MeetingTitleGenerator.resolvedTitle(
            proposedTitle: "Quarterly board meeting",
            summary: "",
            keyPoints: [],
            transcript: [],
            fallbackTitle: "Meeting — Thu 2:14 PM"
        )

        #expect(title == "Quarterly board meeting")
    }

    @Test
    func generatedMeetingTitleStripsSummaryLeadIns() {
        let title = MeetingTitleGenerator.resolvedTitle(
            proposedTitle: "Meeting",
            summary: "The discussion focused on accessibility fixes for the notes editor.",
            keyPoints: [],
            transcript: [],
            fallbackTitle: "Meeting — Thu 2:14 PM"
        )

        #expect(title == "Accessibility fixes for the notes editor")
    }

    @Test
    func generatedMeetingTitleUsesFallbackOnlyWithoutUsefulContent() {
        let fallback = "Meeting — Thu 2:14 PM"
        let title = MeetingTitleGenerator.resolvedTitle(
            proposedTitle: fallback,
            summary: "",
            keyPoints: [],
            transcript: [],
            fallbackTitle: fallback
        )

        #expect(title == fallback)
    }

    @Test
    func meetingWorkspaceUsesThePlainSummaryLabel() {
        #expect(MeetingPanelMode.summary.label == "Summary")
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
        let markdown = try store.rawMarkdown(for: note)
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
    func recordingTopPanelMovesBetweenExpandedCompactAndHiddenStates() {
        let coordinator = MeetingCoordinator(
            store: MarkdownStore(),
            detector: MeetingDetector()
        )
        coordinator.setPreviewState(
            phase: .recording(title: "Design review", startedAt: .now),
            elapsed: 42,
            liveTranscript: .empty,
            audioLevel: 0.2
        )

        coordinator.expandTopPanel()
        #expect(coordinator.showLiveCaptions)
        #expect(!coordinator.topPanelHidden)

        coordinator.collapseTopPanel()
        #expect(!coordinator.showLiveCaptions)
        #expect(!coordinator.topPanelHidden)

        coordinator.hideTopPanel()
        #expect(coordinator.topPanelHidden)

        coordinator.restoreTopPanel()
        #expect(!coordinator.topPanelHidden)
        #expect(!coordinator.showLiveCaptions)
    }

    @Test
    @MainActor
    func statusMenuTracksRecordingCommandsWithoutFollowingTheClock() {
        let store = MarkdownStore()
        let coordinator = MeetingCoordinator(
            store: store,
            detector: MeetingDetector()
        )
        let state = StatusMenuState(
            meeting: coordinator,
            store: store
        )

        #expect(state.phase == .idle)

        coordinator.setPreviewState(
            phase: .recording(title: "Design review", startedAt: .now),
            elapsed: 42,
            liveTranscript: .empty,
            audioLevel: 0.2
        )

        #expect(state.phase == .recording)
        #expect(!state.isPaused)

        coordinator.setPreviewState(
            phase: .recording(title: "Design review", startedAt: .now),
            elapsed: 84,
            liveTranscript: .empty,
            audioLevel: 0,
            isPaused: true
        )
        coordinator.hideTopPanel()

        #expect(state.phase == .recording)
        #expect(state.isPaused)
        #expect(state.topPanelHidden)

        coordinator.restoreTopPanel()
        #expect(!state.topPanelHidden)
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
    func permissionSetupCoversEveryRecordingPermissionInOrder() {
        #expect(
            NookPermission.allCases == [
                .microphone,
                .speechRecognition,
                .screenRecording,
            ]
        )

        for permission in NookPermission.allCases {
            #expect(!permission.title.isEmpty)
            #expect(!permission.setupDescription.isEmpty)
            #expect(!permission.privacyExplanation.isEmpty)
            #expect(!permission.requestActionTitle.isEmpty)
        }
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
    @MainActor
    func screenPermissionRequiresTheDirectCaptureCheck() {
        #expect(
            PermissionSetupController.resolvedScreenRecordingStatus(
                screenCaptureAllowed: true,
                directCaptureVerified: false,
                attempted: true,
                setupFailed: false
            ) == .notRequested
        )
        #expect(
            PermissionSetupController.resolvedScreenRecordingStatus(
                screenCaptureAllowed: true,
                directCaptureVerified: true,
                attempted: true,
                setupFailed: false
            ) == .allowed
        )
    }

    @Test
    @MainActor
    func speechPermissionCallbackMayReturnOffTheMainActor() async {
        let status = await SpeechAssets.requestAuthorizationStatus { completion in
            DispatchQueue.global(qos: .userInitiated).async {
                completion(.authorized)
            }
        }

        #expect(status == .authorized)
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
    func summaryFallbackNeverReclassifiesTranscriptAsStructuredItems() {
        let transcript = [
            TranscriptSegment(
                startTime: 0,
                duration: 8,
                text: "I will explain how the application will render every transcript sentence in the review panel."
            ),
            TranscriptSegment(
                startTime: 9,
                duration: 6,
                text: "We need to follow up on why that behavior is confusing."
            ),
        ]

        let fallback = SummaryService.fallbackInsights(
            transcript: transcript,
            fallbackTitle: "Manual meeting"
        )

        #expect(fallback.keyPoints.isEmpty)
        #expect(fallback.decisions.isEmpty)
        #expect(fallback.actionItems.isEmpty)
        #expect(fallback.summary.contains("Transcript highlights:"))
        #expect(fallback.summary.count < transcript.map(\.text).joined().count + 100)
    }

    @Test
    func groundingValidatesEveryActionAgainstACommitment() {
        let validAction = "Sam — publish the checklist by Friday."
        let proposed = MeetingInsights(
            title: "Launch review",
            summary: "The launch checklist was reviewed.",
            keyPoints: [],
            decisions: [],
            actionItems: [
                validAction,
                "The dashboard currently shows every transcript sentence.",
            ]
        )
        let transcript = [
            TranscriptSegment(
                startTime: 0,
                duration: 4,
                text: "Sam, can you publish the checklist by Friday?"
            ),
            TranscriptSegment(
                startTime: 5,
                duration: 4,
                text: "The dashboard currently shows every transcript sentence."
            ),
        ]

        let grounded = MeetingInsightGrounder.ground(proposed, in: transcript)

        #expect(grounded.actionItems == [validAction])
    }

    @Test
    func summaryValidationDropsTranscriptShapedListItems() throws {
        let proposed = MeetingInsights(
            title: "Launch review",
            summary: "The team reviewed launch readiness and the publication checklist.",
            keyPoints: ["[00:12] System: This is a transcript line."],
            decisions: [],
            actionItems: ["Microphone: I will send the checklist.\nSystem: Thanks." ]
        )

        let validated = try #require(
            MeetingInsightValidator.validate(proposed, against: [])
        )

        #expect(validated.keyPoints.isEmpty)
        #expect(validated.actionItems.isEmpty)
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

/// "My notes" is user-authored free text. People write their own sub-headings
/// in it, and treating those as section boundaries used to cut the field
/// short on decode, then delete the tail permanently when the truncated
/// model was saved back.
struct PersonalNotesSectionTests {
    private func note(withBody body: String) -> MeetingNote? {
        let markdown = """
        ---
        id: 3B9C2A5E-1F4D-4E7A-9C11-8D2F6A0B4E33
        title: "Pricing review"
        started: 2026-07-30T02:00:00Z
        ended: 2026-07-30T03:00:00Z
        source: "Zoom"
        ---

        # Pricing review

        ## Summary

        The team reviewed pricing.

        ## My notes

        \(body)

        ## Transcript

        - **[00:01]** **Meeting:** Shall we start?
        """
        return MarkdownCodec.decode(markdown)
    }

    @Test
    func aUserSubheadingInsideMyNotesSurvivesDecodeAndReEncoding() throws {
        let body = """
        Follow-ups for next time.

        ## Enterprise leads

        Ask about the discount.

        ## Smaller items

        Send the recap.
        """
        let decoded = try #require(note(withBody: body))

        #expect(decoded.personalNotes == body)

        let reDecoded = try #require(
            MarkdownCodec.decode(MarkdownCodec.encode(decoded))
        )
        #expect(reDecoded.personalNotes == body)
    }

    /// The real sections still end the field, so a transcript is never
    /// swallowed into somebody's notes.
    @Test
    func theTranscriptHeadingStillEndsMyNotes() throws {
        let decoded = try #require(note(
            withBody: "Remember to send notes after the call."
        ))

        #expect(decoded.personalNotes == "Remember to send notes after the call.")
    }
}

/// Section markers are boundaries only when they are the whole line. A
/// sentence that quotes a heading is content, and finding it mid-line used
/// to start or end the wrong section.
struct AnchoredSectionTests {
    private let markdown = """
    ---
    id: 3B9C2A5E-1F4D-4E7A-9C11-8D2F6A0B4E33
    title: "Review"
    started: 2026-07-30T02:00:00Z
    ended: 2026-07-30T03:00:00Z
    source: "Zoom"
    ---

    # Review

    ## Summary

    The summary mentioned ## Key points twice in prose.

    ## Key points

    - An actual point

    ## Action items

    - [ ] One action
    """

    @Test
    func aMidLineMentionOfASectionDoesNotBecomeThatSection() {
        #expect(MarkdownCodec.section("Key points", in: markdown)
            .contains("An actual point"))
        #expect(!MarkdownCodec.section("Key points", in: markdown)
            .contains("mentioned"))
    }

    @Test
    func summaryContentQuotingOtherHeadingsStaysIntact() throws {
        let decoded = try #require(MarkdownCodec.decode(markdown))

        #expect(
            decoded.summary
                == "The summary mentioned ## Key points twice in prose."
        )
        #expect(decoded.keyPoints == ["An actual point"])
    }
}

/// A file can carry a heading Nook itself writes more than once: somebody
/// pastes a second "## Summary" in, or a note action appends its result under
/// one. The decoder reads only the first, so the rest used to be swallowed and
/// deleted by the next save.
struct RepeatedHeadingTests {
    private func note() -> MeetingNote {
        MeetingNote(
            title: "Launch review",
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            endedAt: Date(timeIntervalSince1970: 1_780_003_600),
            sourceApp: "Zoom",
            summary: "The team agreed on the launch scope.",
            actionItems: ["Send the pricing page"]
        )
    }

    @Test
    func aSecondSummaryHeadingSurvivesReEncoding() throws {
        let handEdited = MarkdownCodec.encode(note())
            .replacingOccurrences(
                of: "## My notes",
                with: """
                ## Summary

                Added by hand: we also settled the beta list.

                ## My notes
                """
            )

        let decoded = try #require(MarkdownCodec.decode(handEdited))
        #expect(decoded.summary == "The team agreed on the launch scope.")

        let reencoded = MarkdownCodec.encode(decoded)
        #expect(reencoded.contains("The team agreed on the launch scope."))
        #expect(
            reencoded.contains("Added by hand: we also settled the beta list.")
        )

        // And it is still there after the next save, rather than surviving one
        // round trip and going on the one after it.
        let again = try #require(MarkdownCodec.decode(reencoded))
        #expect(
            MarkdownCodec.encode(again)
                .contains("Added by hand: we also settled the beta list.")
        )
    }

    @Test
    func aSectionWrittenUnderARepeatedHeadingIsKeptToo() throws {
        let handEdited = MarkdownCodec.encode(note())
            .replacingOccurrences(
                of: "## My notes",
                with: """
                ## Summary

                Added by hand: we also settled the beta list.

                ## Agenda

                Pricing, then the beta list.

                ## My notes
                """
            )

        let decoded = try #require(MarkdownCodec.decode(handEdited))
        let reencoded = MarkdownCodec.encode(decoded)

        #expect(
            reencoded.contains("Added by hand: we also settled the beta list.")
        )
        #expect(reencoded.contains("Pricing, then the beta list."))
    }
}

/// Moments are flagged offsets in frontmatter, so they survive every
/// re-encoding the note goes through and never pollute portable body text.
struct MomentRoundTripTests {
    @Test
    func flaggedMomentsSurviveDecodeAndReEncoding() throws {
        let note = MeetingNote(
            title: "Design review",
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            endedAt: Date(timeIntervalSince1970: 1_000_600),
            sourceApp: "Zoom",
            summary: "The team reviewed the redesign.",
            transcript: [
                TranscriptSegment(startTime: 10, duration: 2, text: "Hello")
            ],
            moments: [
                MeetingMoment(offset: 61.5),
                MeetingMoment(offset: 3_725)
            ]
        )

        let encoded = MarkdownCodec.encode(note)
        #expect(encoded.contains("moments: 61.5,3725.0"))

        let decoded = try #require(MarkdownCodec.decode(encoded))
        #expect(decoded.moments.map(\.offset) == [61.5, 3_725])
        #expect(MarkdownCodec.encode(decoded) == encoded)

        // A moment near an hour renders with the hour included.
        #expect(decoded.moments.last?.timestamp == "01:02:05")
    }

    /// Spoken notes have no recording timeline, so moments never apply.
    @Test
    func spokenNotesCarryNoMoments() throws {
        var spoken = MeetingNote(
            kind: .spoken,
            title: "Remember the thing",
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            endedAt: Date(timeIntervalSince1970: 1_000_030),
            sourceApp: "Spoken note",
            summary: "Remember to renew the parking permit."
        )
        spoken.moments = [MeetingMoment(offset: 5)]

        let decoded = try #require(
            MarkdownCodec.decode(MarkdownCodec.encode(spoken))
        )
        #expect(decoded.moments.isEmpty)
    }

    @Test
    func notesWithoutAMomentsLineDecodeToEmpty() throws {
        let markdown = """
        ---
        id: 3B9C2A5E-1F4D-4E7A-9C11-8D2F6A0B4E33
        title: "Older meeting"
        started: 2026-07-30T02:00:00Z
        ended: 2026-07-30T03:00:00Z
        source: "Zoom"
        ---

        # Older meeting

        ## Summary

        Before moments existed.

        ## Transcript

        - **[00:01]** **Meeting:** Hello everyone.
        """

        let decoded = try #require(MarkdownCodec.decode(markdown))
        #expect(decoded.moments.isEmpty)
    }
}

/// Toggling an action item must rewrite exactly one line of the file. The
/// alternative, decoding and re-encoding everything, would normalise text the
/// user may be editing by hand at the same time.
struct ActionItemToggleTests {
    private let markdown = """
    ---
    id: 3B9C2A5E-1F4D-4E7A-9C11-8D2F6A0B4E33
    title: "Review"
    started: 2026-07-30T02:00:00Z
    ended: 2026-07-30T03:00:00Z
    source: "Zoom"
    ---

    # Review

    ## Summary

    The team reviewed pricing.

    ## Action items

    - [ ] Draft the tier comparison
    - [x] Book the follow-up
      - [ ] Nested thought stays untouched

    ## My notes

    - [ ] This is a personal note, not an action item.
    """

    @Test
    func checkboxItemsAreListedWithTheirState() {
        let items = MarkdownCodec.actionItemLines(in: markdown)

        #expect(items.count == 3)
        #expect(items[0].text == "Draft the tier comparison")
        #expect(!items[0].isChecked)
        #expect(items[1].isChecked)
        #expect(items[2].text == "Nested thought stays untouched")
    }

    @Test
    func togglingRewritesOneLineAndPreservesEverythingElseByteForByte() throws {
        let target = MarkdownCodec.actionItemLines(in: markdown)[0]
        let rewritten = try #require(
            MarkdownCodec.markdownBySettingActionItem(
                target,
                checked: true,
                in: markdown
            )
        )

        #expect(rewritten.contains("- [x] Draft the tier comparison"))
        // Every other line survives exactly as it was.
        let originalLines = Set(markdown.split(separator: "\n"))
        let rewrittenLines = rewritten.split(separator: "\n")
        #expect(
            rewrittenLines.filter { !originalLines.contains($0) }.count == 1
        )
        #expect(rewritten.contains("  - [ ] Nested thought stays untouched"))
        #expect(rewritten.contains("- [ ] This is a personal note"))
        // Re-encode stability: nothing else moved.
        #expect(
            MarkdownCodec.actionItemLines(in: rewritten)[0].isChecked
        )
    }

    @Test
    func untogglingRestoresTheOpenBox() throws {
        let checked = MarkdownCodec.actionItemLines(in: markdown)[1]
        let rewritten = try #require(
            MarkdownCodec.markdownBySettingActionItem(
                checked,
                checked: false,
                in: markdown
            )
        )

        #expect(rewritten.contains("- [ ] Book the follow-up"))
    }

    @Test
    func aMovedOrMissingItemIsRefusedRatherThanGuessed() throws {
        let items = MarkdownCodec.actionItemLines(in: markdown)
        let stale = ActionItemLine(
            index: items.count + 3,
            text: "Ghost item",
            isChecked: false
        )

        #expect(
            MarkdownCodec.markdownBySettingActionItem(
                stale, checked: true, in: markdown
            ) == nil
        )
        // Same position but different words means the list changed underneath.
        let drifted = ActionItemLine(
            index: 0,
            text: "No longer what it said",
            isChecked: false
        )
        #expect(
            MarkdownCodec.markdownBySettingActionItem(
                drifted, checked: true, in: markdown
            ) == nil
        )
    }
}

/// The decode cache exists so app activation stops re-reading every file.
/// Its whole contract is the timestamp: matching means reuse, anything else
/// means the file changed through some route and must be read again.
@MainActor
struct NoteDecodeCacheTests {
    private func sampleNote() -> MeetingNote {
        MeetingNote(
            title: "Cache probe",
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            endedAt: Date(timeIntervalSince1970: 1_000_060),
            sourceApp: "Zoom",
            summary: "Probe summary"
        )
    }

    @Test
    func anEntrySurvivesOnlyWhileItsTimestampMatches() {
        let cache = NoteDecodeCache()
        let url = URL(fileURLWithPath: "/tmp/probe.md")
        let original = Date(timeIntervalSince1970: 100)

        cache.store(sampleNote(), for: url, modified: original)

        #expect(
            cache.note(for: url, modified: original)?.title
                == "Cache probe"
        )
        #expect(cache.note(for: url, modified: original.addingTimeInterval(1)) == nil)
        #expect(
            cache.note(
                for: URL(fileURLWithPath: "/tmp/other.md"),
                modified: original
            ) == nil
        )

        cache.clear()
        #expect(cache.note(for: url, modified: original) == nil)
    }
}

// MARK: - Spoken-note checklists

extension MarkdownCodecTests {
    private func spokenMarkdown() -> String {
        """
        ---
        id: 11111111-2222-3333-4444-555555555555
        kind: spoken
        title: "Test note"
        started: 2026-08-23T09:00:00Z
        ended: 2026-08-23T09:05:00Z
        source: "Spoken note"
        ---

        # Test note

        Kickoff went well.
        - [ ] Send Marco the report [due: 2026-08-28]
        - [x] Book the room
        Plain closing thought.
        """
    }

    @Test
    func spokenCheckboxesAreFoundAnywhereInTheBody() {
        let lines = MarkdownCodec.spokenCheckboxLines(in: spokenMarkdown())

        #expect(lines.count == 2)
        #expect(lines[0].index == 0)
        #expect(lines[0].text == "Send Marco the report [due: 2026-08-28]")
        #expect(lines[0].isChecked == false)
        #expect(lines[0].dueDate != nil)
        #expect(lines[1].isChecked == true)
        #expect(lines[1].displayText == "Book the room")
    }

    @Test
    func frontmatterNeverMasqueradesAsTasks() {
        let markdown = """
        ---
        id: 11111111-2222-3333-4444-555555555555
        kind: spoken
        title: "- [ ] fake task in frontmatter"
        started: 2026-08-23T09:00:00Z
        ended: 2026-08-23T09:05:00Z
        source: "Spoken note"
        ---

        # Real note

        Nothing to do here.
        """
        #expect(MarkdownCodec.spokenCheckboxLines(in: markdown).isEmpty)
    }

    @Test
    func meetingNotesKeepSectionScoping() {
        // A checkbox quoted inside a meeting's Summary prose must not leak
        // into the action pipeline; only the Action items section counts.
        let markdown = """
        ---
        id: 11111111-2222-3333-4444-555555555555
        kind: meeting
        title: "Weekly sync"
        started: 2026-08-23T09:00:00Z
        ended: 2026-08-23T09:30:00Z
        source: "Zoom"
        ---

        # Weekly sync

        ## Summary

        Someone wrote "- [ ] not a real item" in chat.

        ## Action items

        - [ ] The real item
        """
        let lines = MarkdownCodec.actionItemLines(in: markdown)
        #expect(lines.count == 1)
        #expect(lines[0].text == "The real item")
    }

    @Test
    func togglingASpokenCheckboxTouchesExactlyOneLine() throws {
        let original = spokenMarkdown()
        let lines = MarkdownCodec.spokenCheckboxLines(in: original)
        let rewritten = try #require(
            MarkdownCodec.markdownBySettingSpokenCheckbox(
                lines[0],
                checked: true,
                in: original
            )
        )

        #expect(rewritten.contains("- [x] Send Marco the report"))
        // Every other byte, including the second item and the prose, stays.
        #expect(rewritten.contains("- [x] Book the room"))
        #expect(rewritten.contains("Plain closing thought."))
        let before = original.split(separator: "\n").map(String.init)
        let after = rewritten.split(separator: "\n").map(String.init)
        var changed = 0
        for (old, new) in zip(before, after) where old != new { changed += 1 }
        #expect(changed == 1)
    }

    @Test
    func staleSpokenItemsAreReportedNotRewritten() {
        let original = spokenMarkdown()
        let lines = MarkdownCodec.spokenCheckboxLines(in: original)
        let moved = ActionItemLine(
            index: 0,
            text: "Text that no longer exists",
            isChecked: false
        )
        #expect(
            MarkdownCodec.markdownBySettingSpokenCheckbox(
                moved,
                checked: true,
                in: original
            ) == nil
        )
        #expect(lines.count == 2)
    }

    @Test
    func dueDatesRoundTripOnSpokenLines() throws {
        let original = spokenMarkdown()
        let lines = MarkdownCodec.spokenCheckboxLines(in: original)
        let cleared = try #require(
            MarkdownCodec.markdownBySettingSpokenCheckboxDue(
                lines[0],
                dueTo: nil,
                in: original
            )
        )
        #expect(cleared.contains("- [ ] Send Marco the report\n"))
        #expect(!cleared.contains("[due:"))

        let calendar = Calendar.current
        let newDue = calendar.date(
            byAdding: .day,
            value: 3,
            to: lines[0].dueDate ?? Date()
        )!
        let redated = try #require(
            MarkdownCodec.markdownBySettingSpokenCheckboxDue(
                ActionItemLine(index: 0, text: lines[0].displayText, isChecked: false),
                dueTo: newDue,
                in: cleared
            )
        )
        let reparsed = MarkdownCodec.spokenCheckboxLines(in: redated)[0]
        #expect(reparsed.dueDate != nil)
    }

    @Test
    func aSpokenNoteEncodesAndDecodesWithItsBodyIntact() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let body = """
        Standup notes.
        - [ ] File the incident report [due: 2026-09-01]
        Closing line.
        """
        let note = MeetingNote(
            kind: .spoken,
            title: "Standup",
            startedAt: start,
            endedAt: start.addingTimeInterval(300),
            sourceApp: "Spoken note",
            summary: body
        )

        let decoded = try #require(MarkdownCodec.decode(MarkdownCodec.encode(note)))
        #expect(decoded.kind == .spoken)
        #expect(decoded.summary == body)
        // The pipeline finds the items from the file the encoder wrote.
        let lines = MarkdownCodec.spokenCheckboxLines(in: MarkdownCodec.encode(note))
        #expect(lines.count == 1)
        #expect(lines[0].displayText == "File the incident report")
        #expect(lines[0].dueDate != nil)
    }
}

// MARK: - Note templates

extension MarkdownCodecTests {
    @Test
    func templatesSeedOrdinaryActionItemFields() {
        for template in NoteTemplate.allCases {
            #expect(!template.menuTitle.isEmpty)
            #expect(!template.title.isEmpty)
        }
        #expect(NoteTemplate.blank.actionItems.isEmpty)
        #expect(!NoteTemplate.standup.actionItems.isEmpty)
        // Seeds are plain strings, so they encode as ordinary checkboxes.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let note = MeetingNote(
            title: NoteTemplate.standup.title,
            startedAt: start,
            endedAt: start,
            sourceApp: "Personal",
            summary: "",
            actionItems: NoteTemplate.standup.actionItems
        )
        let markdown = MarkdownCodec.encode(note)
        let lines = MarkdownCodec.actionItemLines(in: markdown)
        #expect(lines.map(\.displayText) == NoteTemplate.standup.actionItems)
        #expect(lines.allSatisfy { !$0.isChecked })
    }
}
