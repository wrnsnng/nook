import AppKit
import ApplicationServices
import Foundation

/// A plain copy of the few Accessibility attributes the Zoom reader looks at.
/// Copied out of `AXUIElement` so the rules below are pure and testable
/// without Zoom running.
struct AccessibilitySnapshotNode: Equatable, Sendable {
    var role: String
    var description: String?
    var value: String?
    var identifier: String?
    var size: CGSize = .zero
    var children: [AccessibilitySnapshotNode] = []
}

/// What Zoom's meeting window showed at one moment.
struct ZoomMeetingReading: Equatable, Sendable {
    /// Everyone listed, without the user and without Zoom's role tags.
    var participants: [String] = []
    /// The user's own display name, from the row Zoom marks "(me)".
    var selfName: String?
    /// Who Zoom presented as talking, when it can be told.
    var activeSpeaker: String?
    /// Tiles whose mute state matched the user's own mute button at this
    /// moment, or nil when the toolbar was hidden. The user is the one tile
    /// that matches at every reading; see `MeetingRosterRecorder`.
    var selfCandidates: Set<String>?
}

/// Reads participant names and the active speaker from the Zoom desktop
/// app's meeting window, through the Accessibility permission Nook already
/// uses for dictation. It never prompts for that permission: without it, or
/// without a Zoom meeting, it reads nothing and naming falls back to the
/// calendar and the user.
///
/// What Zoom exposes was checked against Zoom 7.1 for macOS:
///
/// - Each video tile is an `AXTabGroup` described as
///   "Ana Ruiz, Computer audio unmuted, Video off".
/// - The participants panel, when open, is an `AXOutline` described as
///   "Participants list" whose rows read "Ana Ruiz (Host)" and
///   "Jo Kay (me)".
/// - With three or more people, the talking person's tile gains a trailing
///   "active speaker" field. That is the signal relied on.
/// - The toolbar's microphone button (identifier "audio") reads "Mute my
///   audio" or "Unmute my audio": the user's own state, visible only while
///   the toolbar is shown. Without the panel nothing else marks the user.
/// - With two, Zoom marks nobody. In Speaker View it still gives the other
///   person the one large tile, so that is the next signal, and beyond it the
///   only evidence is that exactly one other person is unmuted.
///
/// Zoom changes its window between releases, so every rule here fails
/// towards reading nothing rather than reading the wrong name.
enum ZoomRosterParser {
    /// The large tile must be at least this many times the area of every
    /// other tile to count as Speaker View's active speaker. Gallery tiles
    /// are equal; Speaker View's thumbnails are tiny by comparison.
    static let speakerViewAreaRatio: CGFloat = 4

    static func reading(from window: AccessibilitySnapshotNode) -> ZoomMeetingReading {
        var tiles: [Tile] = []
        var rows: [(name: String, isSelf: Bool, unmuted: Bool?)] = []
        var userUnmuted: Bool?
        collect(window, tiles: &tiles, rows: &rows, userUnmuted: &userUnmuted, inParticipantList: false)

        let selfName = rows.first(where: \.isSelf)?.name
        var participants: [String] = []
        for name in rows.map(\.name) + tiles.map(\.name)
        where name != selfName && !participants.contains(name) {
            participants.append(name)
        }

        return ZoomMeetingReading(
            participants: participants,
            selfName: selfName,
            activeSpeaker: activeSpeaker(tiles: tiles, rows: rows, selfName: selfName),
            selfCandidates: userUnmuted.map { state in
                Set(tiles.filter { $0.unmuted == state }.map(\.name))
            }
        )
    }

    private static func activeSpeaker(
        tiles: [Tile],
        rows: [(name: String, isSelf: Bool, unmuted: Bool?)],
        selfName: String?
    ) -> String? {
        // Zoom's own marker. When it marks the user, someone is known to be
        // talking and it is not a remote voice, so no weaker rule may guess.
        // Speaker View repeats the speaker in the large tile, so the same
        // name can be marked twice.
        let marked = Set(tiles.filter(\.isActiveSpeaker).map(\.name))
        if marked.count == 1, let name = marked.first {
            return name == selfName ? nil : name
        }
        if marked.count > 1 { return nil }

        // Speaker View: one tile far larger than the rest. A muted person
        // cannot be the one talking, whatever the layout says.
        let bySize = tiles.sorted { $0.area > $1.area }
        if let largest = bySize.first, largest.area > 0,
           bySize.dropFirst().allSatisfy({ $0.area * speakerViewAreaRatio <= largest.area }),
           bySize.count > 1,
           largest.name != selfName,
           largest.unmuted != false {
            return largest.name
        }

        // Any layout: exactly one other person unmuted. Rows are preferred,
        // since the panel lists everyone and tiles may be paged out of view.
        var unmuted: [String: Bool] = [:]
        for tile in tiles { if let state = tile.unmuted { unmuted[tile.name] = state } }
        for row in rows { if let state = row.unmuted { unmuted[row.name] = state } }
        let talking = unmuted.filter { $0.value && $0.key != selfName }.map(\.key)
        return talking.count == 1 ? talking[0] : nil
    }

    private static func collect(
        _ node: AccessibilitySnapshotNode,
        tiles: inout [Tile],
        rows: inout [(name: String, isSelf: Bool, unmuted: Bool?)],
        userUnmuted: inout Bool?,
        inParticipantList: Bool
    ) {
        if userUnmuted == nil, node.identifier == "audio", let description = node.description {
            switch description.lowercased() {
            case "mute my audio": userUnmuted = true
            case "unmute my audio": userUnmuted = false
            default: break
            }
        }
        if node.role == "AXTabGroup", let description = node.description,
           let tile = tile(from: description) {
            tiles.append(Tile(
                name: tile.name, unmuted: tile.unmuted,
                isActiveSpeaker: tile.isActiveSpeaker, area: node.size.width * node.size.height
            ))
            return
        }
        if inParticipantList, node.role == "AXRow" {
            if let row = row(from: node) { rows.append(row) }
            return
        }
        let entersList = node.role == "AXOutline" && node.description == "Participants list"
        for child in node.children {
            collect(
                child, tiles: &tiles, rows: &rows, userUnmuted: &userUnmuted,
                inParticipantList: inParticipantList || entersList
            )
        }
    }

    struct Tile {
        let name: String
        let unmuted: Bool?
        let isActiveSpeaker: Bool
        let area: CGFloat
    }

    /// "Ana Ruiz, Computer audio unmuted, Video off, active speaker" →
    /// ("Ana Ruiz", unmuted, speaking). Status fields are peeled off the end,
    /// so a comma inside a name stays.
    static func tile(from description: String) -> (name: String, unmuted: Bool?, isActiveSpeaker: Bool)? {
        var fields = description.components(separatedBy: ", ")
        var unmuted: Bool?
        var isActiveSpeaker = false
        while let last = fields.last, fields.count > 1 {
            if last.lowercased() == "active speaker" {
                isActiveSpeaker = true
            } else if let state = status(last) {
                if let state { unmuted = unmuted ?? state }
            } else {
                break
            }
            fields.removeLast()
        }
        guard fields.count < description.components(separatedBy: ", ").count else {
            // No recognised status at all: not a video tile we understand.
            return nil
        }
        guard let name = cleanedName(fields.joined(separator: ", ")) else { return nil }
        return (name, unmuted, isActiveSpeaker)
    }

    /// Whether a trailing field is a status Zoom appends, and if it is,
    /// what it says about the microphone (nil when it says nothing).
    private static func status(_ field: String) -> Bool?? {
        let lower = field.lowercased()
        if lower.hasSuffix("audio unmuted") { return .some(true) }
        if lower.hasSuffix("audio muted") { return .some(false) }
        if lower.hasPrefix("video ") || lower == "no audio" || lower.hasPrefix("telephone")
            || lower.hasPrefix("screen sharing") || lower == "pinned" || lower == "spotlighted" {
            return .some(nil)
        }
        return nil
    }

    private static func row(from node: AccessibilitySnapshotNode) -> (name: String, isSelf: Bool, unmuted: Bool?)? {
        var text: String?
        var unmuted: Bool?
        func walk(_ node: AccessibilitySnapshotNode) {
            if node.role == "AXStaticText", text == nil, let value = node.value { text = value }
            if node.role == "AXImage", let description = node.description, case .some(let state?) = status(description) {
                unmuted = state
            }
            node.children.forEach(walk)
        }
        walk(node)
        guard let text else { return nil }
        let isSelf = text.range(of: #"\((me|Me|ME)\)"#, options: .regularExpression) != nil
        guard let name = cleanedName(text) else { return nil }
        return (name, isSelf, unmuted)
    }

    /// Zoom's own tags, never part of anyone's name.
    private static let roleTags = #"\s*\((me|Me|ME|Host|host|Co-host|co-host|Co-Host|Guest|guest|Interpreter|Participant ID: [^)]*)\)\s*$"#

    static func cleanedName(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let range = name.range(of: roleTags, options: .regularExpression) {
            name.removeSubrange(range)
        }
        // Zoom's own placeholders are not people.
        guard !name.isEmpty, !name.lowercased().hasPrefix("participants (") else { return nil }
        return SpeakerNames.sanitized(name)
    }
}

/// Copies Zoom's meeting window out of the Accessibility API. Bounded in depth
/// and node count because Zoom's toolbar can report itself as its own child,
/// which an unbounded walk would follow forever.
enum ZoomAccessibilityReader {
    static let zoomBundleIdentifier = "us.zoom.xos"
    private static let maximumDepth = 14
    private static let maximumNodes = 1_500

    /// Reads the meeting window, or nil when there is no permission, no Zoom
    /// meeting window, or Zoom does not answer in time. Called off the main
    /// actor: a slow app can hold an Accessibility call for its timeout.
    nonisolated static func readMeeting() -> ZoomMeetingReading? {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication
                  .runningApplications(withBundleIdentifier: zoomBundleIdentifier).first
        else { return nil }

        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.3)
        guard let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement],
              let meeting = windows.first(where: {
                  string(attribute($0, kAXIdentifierAttribute)) == "zm.meeting.window.main"
              })
        else { return nil }

        var budget = maximumNodes
        let snapshot = copy(meeting, depth: 0, budget: &budget)
        return ZoomRosterParser.reading(from: snapshot)
    }

    nonisolated private static func copy(
        _ element: AXUIElement, depth: Int, budget: inout Int
    ) -> AccessibilitySnapshotNode {
        budget -= 1
        var node = AccessibilitySnapshotNode(
            role: string(attribute(element, kAXRoleAttribute)) ?? "",
            description: string(attribute(element, kAXDescriptionAttribute)),
            value: string(attribute(element, kAXValueAttribute)),
            identifier: string(attribute(element, kAXIdentifierAttribute))
        )
        if node.role == "AXTabGroup", let size = attribute(element, kAXSizeAttribute),
           CFGetTypeID(size) == AXValueGetTypeID() {
            var value = CGSize.zero
            // Force cast is safe: the type ID was checked on the line above.
            if AXValueGetValue(size as! AXValue, .cgSize, &value) { node.size = value }
        }
        // A tile's own children are its name label and buttons; the
        // description already carries everything needed.
        guard node.role != "AXTabGroup", depth < maximumDepth,
              let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement]
        else { return node }
        for child in children {
            guard budget > 0 else { break }
            node.children.append(copy(child, depth: depth + 1, budget: &budget))
        }
        return node
    }

    nonisolated private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    nonisolated private static func string(_ value: AnyObject?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}
