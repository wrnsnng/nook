import Foundation
import Testing
@testable import Nook

/// Shapes copied from Zoom 7.1's meeting window, with synthetic names.
struct ZoomRosterReaderTests {
    private func tile(_ description: String, _ width: CGFloat, _ height: CGFloat) -> AccessibilitySnapshotNode {
        AccessibilitySnapshotNode(
            role: "AXTabGroup", description: description, size: CGSize(width: width, height: height)
        )
    }

    private func row(_ text: String, audio: String? = nil) -> AccessibilitySnapshotNode {
        var children = [AccessibilitySnapshotNode(role: "AXStaticText", value: text)]
        if let audio { children.append(AccessibilitySnapshotNode(role: "AXImage", description: audio)) }
        return AccessibilitySnapshotNode(
            role: "AXRow",
            children: [AccessibilitySnapshotNode(role: "AXCell", children: children)]
        )
    }

    private func window(
        tiles: [AccessibilitySnapshotNode], rows: [AccessibilitySnapshotNode] = []
    ) -> AccessibilitySnapshotNode {
        var children = tiles
        if !rows.isEmpty {
            children.append(AccessibilitySnapshotNode(role: "AXScrollArea", children: [
                AccessibilitySnapshotNode(role: "AXOutline", description: "Participants list", children: rows),
            ]))
        }
        children.append(AccessibilitySnapshotNode(role: "AXButton", description: "Mute me"))
        return AccessibilitySnapshotNode(role: "AXWindow", identifier: "zm.meeting.window.main", children: children)
    }

    /// Speaker View's large tile is the person talking; the user's own name,
    /// marked "(me)" in the list, is never a participant or a speaker.
    @Test
    func speakerViewNamesTheLargeTile() {
        let reading = ZoomRosterParser.reading(from: window(
            tiles: [
                tile("Ana Ruiz (CTR), Computer audio unmuted", 2670, 1502),
                tile("Jo Kay, Computer audio muted, Video off", 320, 180),
            ],
            rows: [
                row("Jo Kay (me)"),
                row("Ana Ruiz (CTR) (Host)", audio: "Computer audio unmuted"),
            ]
        ))
        #expect(reading.selfName == "Jo Kay")
        #expect(reading.participants == ["Ana Ruiz (CTR)"])
        #expect(reading.activeSpeaker == "Ana Ruiz (CTR)")
    }

    /// With three or more people Zoom marks the talking tile itself, and in
    /// Speaker View repeats it in the large tile. When the mark is on the
    /// user, nobody on the other end is named, whatever the large tile shows.
    @Test
    func zoomsOwnActiveSpeakerMarkWins() {
        let speaking = window(tiles: [
            tile("Ben Ode, Computer audio unmuted", 2670, 1502),
            tile("Jo Kay, Computer audio muted, Video off", 320, 180),
            tile("Ben Ode, Computer audio unmuted, Video off, active speaker", 320, 180),
            tile("Cy Lam, Computer audio unmuted, Video off", 320, 180),
        ], rows: [AccessibilitySnapshotNode(role: "AXRow", children: [
            AccessibilitySnapshotNode(role: "AXStaticText", value: "Jo Kay (me)"),
        ])])
        let reading = ZoomRosterParser.reading(from: speaking)
        #expect(reading.activeSpeaker == "Ben Ode")
        #expect(reading.participants == ["Ben Ode", "Cy Lam"])

        let userSpeaking = window(tiles: [
            tile("Ben Ode, Computer audio unmuted", 2670, 1502),
            tile("Jo Kay, Computer audio unmuted, Video off, active speaker", 320, 180),
            tile("Ben Ode, Computer audio unmuted, Video off", 320, 180),
        ], rows: [AccessibilitySnapshotNode(role: "AXRow", children: [
            AccessibilitySnapshotNode(role: "AXStaticText", value: "Jo Kay (me)"),
        ])])
        #expect(ZoomRosterParser.reading(from: userSpeaking).activeSpeaker == nil)
    }

    /// In Gallery View, equal tiles say nothing about who is talking; one
    /// other person unmuted does.
    @Test
    func galleryViewFallsBackToTheOnlyUnmutedPerson() {
        let gallery = window(tiles: [
            tile("Ana Ruiz, Computer audio muted, Video off", 1456, 819),
            tile("Ben Ode, Computer audio unmuted, Video off", 1456, 819),
            tile("Cy Lam, Computer audio muted", 1456, 819),
        ])
        #expect(ZoomRosterParser.reading(from: gallery).activeSpeaker == "Ben Ode")

        let twoUnmuted = window(tiles: [
            tile("Ana Ruiz, Computer audio unmuted, Video off", 1456, 819),
            tile("Ben Ode, Computer audio unmuted, Video off", 1456, 819),
        ])
        #expect(ZoomRosterParser.reading(from: twoUnmuted).activeSpeaker == nil)
    }

    /// A muted person in the large tile is not talking, and the user is
    /// never their own active speaker.
    @Test
    func neitherAMutedTileNorTheUserIsTheSpeaker() {
        let muted = window(tiles: [
            tile("Ana Ruiz, Computer audio muted", 2670, 1502),
            tile("Jo Kay, Computer audio muted", 320, 180),
        ])
        #expect(ZoomRosterParser.reading(from: muted).activeSpeaker == nil)

        let selfLarge = window(
            tiles: [
                tile("Jo Kay, Computer audio unmuted", 2670, 1502),
                tile("Ana Ruiz, Computer audio muted", 320, 180),
            ],
            rows: [row("Jo Kay (me)")]
        )
        #expect(ZoomRosterParser.reading(from: selfLarge).activeSpeaker == nil)
    }

    /// Zoom's role tags come off; commas inside a name stay; elements that
    /// are not tiles are ignored.
    @Test
    func namesAreCleanedOfZoomsOwnTags() {
        #expect(ZoomRosterParser.cleanedName("Ana Ruiz (Co-host)") == "Ana Ruiz")
        #expect(ZoomRosterParser.cleanedName("Ana Ruiz (CTR) (Host)") == "Ana Ruiz (CTR)")
        #expect(ZoomRosterParser.cleanedName("Participants (2)") == nil)
        #expect(ZoomRosterParser.tile(from: "Ruiz, Ana, Computer audio muted")?.name == "Ruiz, Ana")
        #expect(ZoomRosterParser.tile(from: "Press Control+Command+Arrow key") == nil)
    }

    /// Readings land on the recording timeline; the user's name is dropped
    /// even when Zoom only revealed it partway through.
    @MainActor
    @Test
    func theRecorderKeepsParticipantsAndSpeakersButNotTheUser() {
        let recorder = MeetingRosterRecorder(read: { nil }, isEnabled: { false })
        recorder.record(ZoomMeetingReading(participants: ["Ana Ruiz", "Jo Kay"], activeSpeaker: "Jo Kay"), at: 1)
        recorder.record(ZoomMeetingReading(participants: ["Ana Ruiz"], selfName: "Jo Kay", activeSpeaker: "Ana Ruiz"), at: 2)
        let roster = recorder.stop()
        #expect(roster.participants == ["Ana Ruiz"])
        #expect(roster.selfName == "Jo Kay")
        // The early "Jo Kay" reading stays, but matching excludes it by name.
        #expect(roster.activeSpeakers.map(\.name) == ["Jo Kay", "Ana Ruiz"])
    }

    /// With the participants panel closed, the user is found as the one tile
    /// whose mute state always matched their own mute button, as in a live
    /// Zoom 7.1 trace. Readings without the toolbar say nothing either way.
    @MainActor
    @Test
    func theUserIsFoundByTheirOwnMuteButton() {
        func reading(userUnmuted: Bool?) -> AccessibilitySnapshotNode {
            var children = [
                tile("Ana Ruiz, Computer audio unmuted, Video off", 160, 90),
                tile("Jo Kay, Computer audio muted, Video off", 160, 90),
                tile("Ben Ode, Computer audio muted, Video off", 160, 90),
            ]
            if let userUnmuted {
                children.append(AccessibilitySnapshotNode(
                    role: "AXButton",
                    description: userUnmuted ? "Mute my audio" : "Unmute my audio",
                    identifier: "audio"
                ))
            }
            return AccessibilitySnapshotNode(role: "AXWindow", children: children)
        }
        let first = ZoomRosterParser.reading(from: reading(userUnmuted: false))
        #expect(first.selfCandidates == ["Jo Kay", "Ben Ode"])
        #expect(ZoomRosterParser.reading(from: reading(userUnmuted: nil)).selfCandidates == nil)

        let recorder = MeetingRosterRecorder(read: { nil }, isEnabled: { false })
        recorder.record(first, at: 1)
        // Ben unmutes while the user stays muted, which tells them apart.
        var later = first
        later.selfCandidates = ["Jo Kay"]
        recorder.record(later, at: 2)
        recorder.record(ZoomRosterParser.reading(from: reading(userUnmuted: nil)), at: 3)
        let roster = recorder.stop()
        #expect(roster.selfName == "Jo Kay")
        #expect(!roster.participants.contains("Jo Kay"))
    }

    /// While nobody's mute state has told the user apart, nobody is assumed.
    @MainActor
    @Test
    func anUnresolvedMuteStateAssumesNobody() {
        let recorder = MeetingRosterRecorder(read: { nil }, isEnabled: { false })
        recorder.record(ZoomMeetingReading(participants: ["Jo Kay", "Ben Ode"], selfCandidates: ["Jo Kay", "Ben Ode"]), at: 1)
        let roster = recorder.stop()
        #expect(roster.selfName == nil)
        #expect(roster.participants == ["Jo Kay", "Ben Ode"])
    }
}
