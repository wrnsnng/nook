import Foundation

/// Recognition proposes an edit; it never authorizes one. Only complete
/// utterances match, so quoted commands and ordinary prose remain words.
enum VoiceCorrectionIntent: Equatable, Sendable {
    case scratchThat
    case changePreviousItem(replacement: String?)

    static func parse(_ utterance: String) -> Self? {
        let words = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        var command = words.lowercased()
        while let last = command.last, ".!?".contains(last) { command.removeLast() }
        if command == "scratch that" { return .scratchThat }
        if command == "change the previous item" { return .changePreviousItem(replacement: nil) }
        let prefix = "change the previous item to "
        guard let range = words.range(of: prefix, options: [.anchored, .caseInsensitive]) else { return nil }
        let replacement = String(words[range.upperBound...])
        guard !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .changePreviousItem(replacement: replacement)
    }
}

struct DictatedEdit: Sendable {
    let before: String
    let after: String
}

struct VoiceCorrectionProposal: Identifiable, Sendable {
    let id = UUID()
    let intent: VoiceCorrectionIntent
    let utterance: String
    let beforeCommand: String
    /// Includes the literal command, already in the normal autosave path.
    let expectedText: String
    let targetRange: NSRange

    var originalWords: String { (beforeCommand as NSString).substring(with: targetRange) }
    var replacement: String {
        if case .changePreviousItem(let words) = intent { return words ?? "" }
        return ""
    }
    var isRemoval: Bool { intent == .scratchThat }

    func correctedText(replacement: String) -> String? {
        guard isRemoval || !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (beforeCommand as NSString).replacingCharacters(in: targetRange, with: isRemoval ? "" : replacement)
    }

    static func make(
        intent: VoiceCorrectionIntent, utterance: String, before: String,
        literalText: String, previous: DictatedEdit?
    ) -> Self? {
        let range: NSRange
        switch intent {
        case .scratchThat:
            guard let previous, previous.after.utf8.elementsEqual(before.utf8),
                  before.utf8.starts(with: previous.before.utf8),
                  before.utf16.count > previous.before.utf16.count else { return nil }
            range = NSRange(location: previous.before.utf16.count,
                            length: before.utf16.count - previous.before.utf16.count)
        case .changePreviousItem:
            guard let item = previousItemBody(in: before) else { return nil }
            range = item
        }
        return Self(intent: intent, utterance: utterance, beforeCommand: before,
                    expectedText: literalText, targetRange: range)
    }

    /// The last nonempty line must itself be a plain list item. Do not guess
    /// which earlier item a paragraph, continuation, blockquote or code means.
    private static func previousItemBody(in text: String) -> NSRange? {
        let lines = text.components(separatedBy: "\n")
        guard let last = lines.lastIndex(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return nil }
        var fence: (Character, Int)?
        for line in lines[..<last] {
            let indentation = line.prefix(while: { $0 == " " }).count
            guard indentation <= 3 else { continue }
            let trimmed = line.dropFirst(indentation)
            guard let first = trimmed.first, first == "`" || first == "~" else { continue }
            let count = trimmed.prefix(while: { $0 == first }).count
            guard count >= 3 else { continue }
            if let current = fence {
                // A fence followed by text is not a closing fence. Treating
                // it as one could authorize editing a list-shaped code line.
                if first == current.0, count >= current.1,
                   trimmed.dropFirst(count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    fence = nil
                }
            } else { fence = (first, count) }
        }
        guard fence == nil,
              let regex = try? NSRegularExpression(pattern: #"^( {0,3}(?:[-*+]|[0-9]+[.)])[ \t]+(?:\[[ xX]\][ \t]+)?)(\S.*?)[ \t\r]*$"#),
              let match = regex.firstMatch(in: lines[last], range: NSRange(location: 0, length: lines[last].utf16.count))
        else { return nil }
        let body = match.range(at: 2)
        let offset = lines[..<last].reduce(0) { $0 + $1.utf16.count + 1 }
        return NSRange(location: offset + body.location, length: body.length)
    }
}
