import Foundation

/// Spoken formatting commands, applied deterministically.
///
/// These are exact-phrase substitutions on settled dictation output, never
/// model work: "new paragraph" becomes a paragraph break exactly as typed.
/// A fixed table cannot mishear into an action, which is why it sits outside
/// the rewrite guard's concerns. Matching ignores surrounding punctuation
/// because recognisers attach sentence punctuation to command words.
enum DictationFormatting {
    private enum Command {
        static let paragraphBreak = "\n\n"
        static let lineBreak = "\n"
    }

    static func apply(to text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var base = normalized(trimmed) else { return text }

        // A trailing full stop belongs to the command word ("new paragraph."),
        // not to whatever follows the break.
        if base.hasSuffix("."), base != "period" {
            base = String(base.dropLast())
        }

        switch base {
        case "new paragraph":
            return Command.paragraphBreak
        case "new line":
            return Command.lineBreak
        default:
            return text
        }
    }

    private static func normalized(_ text: String) -> String? {
        let lowered = text.lowercased()
        guard !lowered.isEmpty else { return nil }
        return lowered
    }
}
