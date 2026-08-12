import Foundation

/// Removes hesitations from dictated speech without a language model.
///
/// Clean-up runs on every finalized chunk while the user is still speaking, so
/// it has to be instant and it has to be predictable. A model can promise
/// neither, and the cost of it inventing a word here is a wrong word typed into
/// someone's document. Everything this filter removes is a closed set.
///
/// The bias throughout is toward leaving a filler in rather than deleting a
/// real word. "Like", "so", "well", and "right" are all common fillers and all
/// common content words, so none of them are touched.
enum DisfluencyFilter {
    static func clean(_ text: String) -> String {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return text }

        var kept: [Token] = []
        var firstKeptIndex: Int?

        for (index, token) in tokens.enumerated() {
            guard !isFiller(token), !isConversationalAside(at: index, in: tokens)
            else {
                absorbComma(from: token, into: &kept)
                continue
            }
            if isImmediateRepetition(of: token, after: kept.last) {
                // Keep the later token's punctuation: "the, the cat" becomes
                // "the cat", not "the, cat".
                kept.removeLast()
                // Collapsing the opening word replaces it with this one, which
                // is mid-sentence and so lowercase. The sentence now starts
                // here, and `restoreOpeningCapital` needs to know that.
                if kept.isEmpty { firstKeptIndex = index }
            }
            if firstKeptIndex == nil { firstKeptIndex = index }
            kept.append(token)
        }

        guard !kept.isEmpty else { return "" }
        restoreOpeningCapital(
            in: &kept,
            firstKeptIndex: firstKeptIndex,
            original: tokens
        )
        return assemble(kept)
    }

    // MARK: - Tokens

    private struct Token {
        /// Letters and digits only, lowercased — what comparisons run against.
        let word: String
        /// The word as spoken, with its original capitalization.
        var stem: String
        /// Punctuation that trailed the word.
        var trailing: String

        var text: String { stem + trailing }
    }

    private static func tokenize(_ text: String) -> [Token] {
        text.split(whereSeparator: \.isWhitespace).map { piece in
            let value = String(piece)
            let trailing = value.reversed()
                .prefix { !$0.isLetter && !$0.isNumber }
                .reversed()
            let stem = value.dropLast(trailing.count)
            return Token(
                word: stem.lowercased().filter { $0.isLetter || $0.isNumber },
                stem: String(stem),
                trailing: String(trailing)
            )
        }
    }

    private static func assemble(_ tokens: [Token]) -> String {
        var pieces = tokens.map(\.text)
        // A dropped opening filler can leave punctuation that only made sense
        // attached to the word that is now gone: ", so I think".
        pieces[0] = String(
            pieces[0].drop { !$0.isLetter && !$0.isNumber }
        )
        return pieces
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Rules

    private static func isFiller(_ token: Token) -> Bool {
        fillers.contains(token.word)
    }

    /// Whether a repeated word is a stutter rather than something meant twice.
    ///
    /// Stutters land on short function words — "I I I think", "the the plan",
    /// "we we should". Longer words repeated are almost always deliberate
    /// ("really really good"), and repeated numbers are usually someone reading
    /// out a code or a phone number, where dropping a digit is silent data
    /// loss the user may not notice until it matters.
    private static func isImmediateRepetition(
        of token: Token,
        after previous: Token?
    ) -> Bool {
        guard let previous, !token.word.isEmpty else { return false }
        guard token.word == previous.word else { return false }
        // Every rule in this file is reasoned about English, and Nook
        // transcribes ten languages. In a script without case — Japanese being
        // the one Nook offers — a repeated character is far more likely to be
        // meaningful than a stumble. Asking whether the script distinguishes
        // case keeps European stutters collapsing ("de de") while leaving those
        // scripts alone, which testing for ASCII would not: it would also have
        // exempted every accented word.
        guard token.word.uppercased() != token.word.lowercased() else {
            return false
        }
        guard !token.word.contains(where: \.isNumber) else { return false }
        guard !numberWords.contains(token.word) else { return false }
        guard token.word.count <= maximumStutterLength else { return false }
        guard !legitimateDoubles.contains(token.word) else { return false }
        return !isSpelledOut(token)
    }

    /// Whether a repeated single letter is being spelled out rather than
    /// stumbled over.
    ///
    /// "I I I think" is a stutter; the "A A" in "A A 7 3" is a confirmation
    /// code, and dropping one is the same silent data loss as dropping a digit.
    ///
    /// Only two single letters are English words, and they are the only ones
    /// that stutter in ordinary speech. Every other letter is therefore treated
    /// as spoken data and never collapsed, whatever surrounds it and however it
    /// is capitalized.
    ///
    /// Casing decides the one genuinely ambiguous case, "a", and nothing else.
    /// It is a weak signal — ordinary dictation is not documented to capitalize
    /// letters that are read out, and is reported to capitalize other words
    /// erratically — so it is confined to the single place where guessing wrong
    /// costs a leftover stutter rather than a deleted word. Relying on it more
    /// widely would put every letter B through Z behind an assumption that has
    /// not been verified against real recognizer output.
    private static func isSpelledOut(_ token: Token) -> Bool {
        guard token.word.count == 1 else { return false }
        guard token.word != "i" else { return false }
        guard token.word == "a" else { return true }
        return token.stem.first?.isUppercase == true
    }

    /// Dropping ", uh," leaves ", ,". When a removed filler carried a comma and
    /// the word before it already ends in one, the earlier comma goes too, so
    /// "we should, uh, ship it" reads as "we should ship it".
    private static func absorbComma(from token: Token, into kept: inout [Token]) {
        guard token.trailing.contains(","),
              let last = kept.last,
              last.trailing.contains(",")
        else {
            return
        }
        kept[kept.count - 1].trailing = last.trailing.replacingOccurrences(
            of: ",",
            with: ""
        )
    }

    /// "You know" and "I mean" are fillers only when set off by commas, which
    /// is how the recognizer punctuates them when they are asides. "Do you know
    /// the time" keeps every word.
    private static func isConversationalAside(
        at index: Int,
        in tokens: [Token]
    ) -> Bool {
        // A phrase is dropped as a unit, so a token also counts when it is the
        // tail of an aside whose opening word was already removed.
        for phrase in asides {
            for offset in 0..<phrase.count {
                let start = index - offset
                guard start >= 0, start + phrase.count <= tokens.count else {
                    continue
                }
                let slice = tokens[start..<(start + phrase.count)]
                guard slice.map(\.word) == phrase else { continue }
                if isDelimitedAside(slice, startingAt: start, in: tokens) {
                    return true
                }
            }
        }
        return false
    }

    private static func isDelimitedAside(
        _ slice: ArraySlice<Token>,
        startingAt start: Int,
        in tokens: [Token]
    ) -> Bool {
        if slice.last?.trailing.contains(",") == true { return true }
        // Being first in the chunk is not evidence of an aside on its own:
        // "You know the answer" opens a sentence and means every word of it.
        guard start > 0 else { return false }
        return tokens[start - 1].trailing.contains(",")
    }

    /// A removed sentence-opening filler leaves the next word lowercase.
    private static func restoreOpeningCapital(
        in kept: inout [Token],
        firstKeptIndex: Int?,
        original: [Token]
    ) {
        guard let firstKeptIndex, firstKeptIndex > 0,
              original.first?.stem.first?.isUppercase == true,
              let initial = kept[0].stem.first,
              initial.isLowercase
        else {
            return
        }
        kept[0].stem = initial.uppercased() + kept[0].stem.dropFirst()
    }

    private static let fillers: Set<String> = [
        "um", "umm", "ummm",
        "uh", "uhh", "uhhh", "uhm",
        "er", "erm", "err",
        "ah", "ahh",
        "eh",
        "hm", "hmm", "hmmm"
    ]

    private static let asides: [[String]] = [
        ["you", "know"],
        ["i", "mean"]
    ]

    /// Beyond this, a repeat reads as emphasis rather than a stutter.
    private static let maximumStutterLength = 3

    /// Short words whose repetition is grammatical or meant: "he had had
    /// enough", "no no, the other one", "yes yes, understood".
    private static let legitimateDoubles: Set<String> = [
        "had", "that", "no", "yes", "bye", "ha"
    ]

    /// Spoken numbers, which the recognizer may render as words rather than
    /// digits. A repeated one is someone reading a code aloud.
    private static let numberWords: Set<String> = [
        "one", "two", "six", "ten", "oh", "nil"
    ]
}
