import Foundation

/// Rejects detectable drift before a model rewrite reaches the user's document.
///
/// Dictation routinely produces text that reads as a request — "summarise the
/// Q3 numbers", "what time is standup" — and a language model handed that text
/// will answer it. The user asked for their sentence to be typed, not replied
/// to. Instructions alone do not reliably prevent this, so the rewrite is
/// checked against the transcript before insertion. These checks are a
/// conservative heuristic, not a security boundary or a proof of equivalent
/// meaning. Arbitrary names, paraphrases and the scope of a negation can still
/// change while retaining the same vocabulary.
///
/// Rejection is cheap: the verbatim words get typed instead, which is a worse
/// sentence but always the user's own. Accepting a bad rewrite is expensive:
/// it puts words the user never said into their message.
enum DictationOutputGuard {
    enum Decision: Equatable {
        case accept(String)
        case reject(Rejection)

        var text: String? {
            guard case .accept(let value) = self else { return nil }
            return value
        }
    }

    enum Rejection: String, Equatable {
        case empty
        case tooShort
        case tooLong
        case driftedFromSpeech
    }

    /// A rewrite may compress speech considerably — removing false starts and
    /// repetition genuinely halves some sentences — but it should never expand
    /// much, and an answer to a dictated question is almost always either far
    /// shorter or far longer than the question.
    static let minimumLengthRatio = 0.35
    static let defaultMaximumLengthRatio = 1.6

    /// How much of the spoken vocabulary must survive. This catches many
    /// answers and unrelated rewrites, but topic overlap alone is not grounding.
    private static let minimumWordOverlap = 0.5

    /// A short sentence can reverse its meaning by changing one word. A
    /// vocabulary ratio is too weak here, so preserve its normalized words.
    private static let shortUtteranceWordCount = 4

    /// `maximumLengthRatio` lets a caller widen the growth ceiling for
    /// rewrites that legitimately develop the text, without loosening the
    /// overlap test that catches an answer replacing the words.
    static func evaluate(
        refined: String,
        spoken: String,
        maximumLengthRatio: Double = Self.defaultMaximumLengthRatio
    ) -> Decision {
        let candidate = refined.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = spoken.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !candidate.isEmpty else { return .reject(.empty) }
        guard !source.isEmpty else { return .reject(.driftedFromSpeech) }

        let ratio = Double(candidate.count) / Double(source.count)
        if ratio < minimumLengthRatio { return .reject(.tooShort) }
        if ratio > maximumLengthRatio { return .reject(.tooLong) }

        let sourceTokens = normalizedWords(in: source)
        let candidateTokens = normalizedWords(in: candidate)
        // Length and topic overlap cannot detect changed amounts, dates,
        // codes, or a dropped negation in a longer sentence. Preserve these
        // recognizable facts in order, including repetitions. Unrecognized
        // names and semantic relationships still need the user's review.
        guard numericTokens(in: source) == numericTokens(in: candidate),
              negations(in: sourceTokens) == negations(in: candidateTokens),
              calendarMarkers(in: sourceTokens) == calendarMarkers(in: candidateTokens)
        else {
            return .reject(.driftedFromSpeech)
        }
        if sourceTokens.count <= shortUtteranceWordCount {
            return sourceTokens == candidateTokens
                ? .accept(candidate)
                : .reject(.driftedFromSpeech)
        }

        let spokenWords = contentWords(in: source)
        let candidateWords = contentWords(in: candidate)
        guard !spokenWords.isEmpty else {
            return sourceTokens == candidateTokens
                ? .accept(candidate)
                : .reject(.driftedFromSpeech)
        }
        let overlap = Double(spokenWords.intersection(candidateWords).count)
            / Double(spokenWords.count)
        guard overlap >= minimumWordOverlap else {
            return .reject(.driftedFromSpeech)
        }
        return .accept(candidate)
    }

    /// Preserve numeric literals with their signs, units and adjacent code
    /// characters. Terminal sentence punctuation is harmless; punctuation
    /// inside a number is meaningful. Written-out number conversion may fall
    /// back to verbatim speech, which is an intentional conservative choice.
    private static func numericTokens(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).compactMap { token in
            let hasCurrency = token.unicodeScalars.contains {
                $0.properties.generalCategory == .currencySymbol
            }
            let standaloneSign = ["+", "-", "−", "%", "‰"].contains(String(token))
            guard token.contains(where: \.isNumber) || hasCurrency || standaloneSign
            else { return nil }
            var literal = String(token)
            // A leading dot can be a decimal point. Trim only sentence-ending
            // punctuation, never the front of a literal or its sign.
            while let last = literal.last, ".,!?;:".contains(last) {
                literal.removeLast()
            }
            return literal
        }
    }

    private static func normalizedWords(in text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "can't", with: "can not")
            .replacingOccurrences(of: "cannot", with: "can not")
            .replacingOccurrences(of: "won't", with: "will not")
            .replacingOccurrences(of: "n't", with: " not")
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private static func negations(in words: [String]) -> [String] {
        var markers: [String] = []
        var hasFrenchNegativeParticle = false
        for word in words {
            if word == "ne" || word == "n" { hasFrenchNegativeParticle = true }
            if negationWords.contains(word) {
                markers.append(word)
                hasFrenchNegativeParticle = false
            } else if word == "plus", hasFrenchNegativeParticle {
                // "Ne ... plus" means no longer. Bare "plus" can mean more,
                // so polarity cannot be inferred from that word on its own.
                markers.append("french-ne-plus")
                hasFrenchNegativeParticle = false
            }
            // Japanese usually has no spaces. Match common negative endings
            // inside a clause instead of relying on whole-word tokenization.
            // Plain and polite forms may change without changing polarity.
            markers += embeddedJapaneseMatches(in: word, expression: japaneseNegation)
                .map { _ in "japanese-negative" }
        }
        return markers
    }

    // Surface forms used by the supported dictation languages. French "ne"
    // and "n'" are intentionally omitted: a faithful tidy can add or remove
    // that optional particle while retaining "pas", "jamais", etc. Homographs
    // can conservatively reject a faithful synonym; this is not a full parser
    // for negative concord, negation scope, or every negative construction.
    private static let negationWords: Set<String> = [
        "no", "not", "never", "neither", "nor", "without",
        "pas", "jamais", "sans", "aucun", "aucune", "personne", "rien", "ni",
        "nicht", "kein", "keine", "keinen", "keinem", "keiner", "keines",
        "keinerlei", "nie", "niemals", "ohne", "weder",
        "nunca", "jamás", "sin", "ningún", "ninguno", "ninguna", "ningunos",
        "ningunas", "tampoco", "nadie", "nada",
        "non", "mai", "senza", "nessun", "nessuno", "nessuna", "niente",
        "nulla", "neanche", "nemmeno", "né",
        "niet", "geen", "nooit", "zonder", "niemand", "niets", "noch",
        "não", "sem", "nenhum", "nenhuma", "nenhuns", "nenhumas", "nem", "ninguém"
    ]

    private static let japaneseNegation = try! NSRegularExpression(
        pattern: "ませんでした|ません|なかった|ない"
    )

    private static func calendarMarkers(in words: [String]) -> [String] {
        words.enumerated().flatMap { index, word -> [String] in
            if let marker = calendarWords[word] {
                // "We may improve this" is an ordinary expansion, not a new
                // date. Require date context for common ambiguous spellings.
                // Bare ambiguous names and abbreviations remain a limitation.
                guard !ambiguousCalendarWords.contains(word)
                    || hasCalendarContext(at: index, in: words) else { return [] }
                return [marker]
            }
            return embeddedJapaneseMatches(in: word, expression: japaneseCalendar)
                .compactMap { calendarWords[$0] }
        }
    }

    private static func hasCalendarContext(at index: Int, in words: [String]) -> Bool {
        let previous = index > 0 ? words[index - 1] : ""
        let next = index + 1 < words.count ? words[index + 1] : ""
        return previous.contains(where: \.isNumber) || next.contains(where: \.isNumber)
            || calendarIntroductions.contains(previous)
    }

    private static let ambiguousCalendarWords: Set<String> = ["may", "march", "mai", "august"]
    private static let calendarIntroductions: Set<String> = [
        "in", "during", "since", "until", "before", "after", "through", "by",
        "of", "for", "next", "last", "on", "im", "am", "bis", "seit", "vor",
        "nach", "diesen", "nächsten", "letzten", "en", "au", "depuis", "avant",
        "après", "de", "em", "no", "na", "até", "desde", "nel", "a", "di"
    ]

    // Full weekday/month names, with equivalent spellings sharing a marker.
    // Portuguese hyphenated weekdays are split into "sexta", "feira", etc.
    // Only known calendar words are constrained, not all novel rewrite words.
    private static let calendarWords: [String: String] = {
        let groups = [
            ["monday", "montag", "lundi", "lunes", "lunedì", "maandag", "segunda", "月曜", "月曜日"],
            ["tuesday", "dienstag", "mardi", "martes", "martedì", "dinsdag", "terça", "火曜", "火曜日"],
            ["wednesday", "mittwoch", "mercredi", "miércoles", "mercoledì", "woensdag", "quarta", "水曜", "水曜日"],
            ["thursday", "donnerstag", "jeudi", "jueves", "giovedì", "donderdag", "quinta", "木曜", "木曜日"],
            ["friday", "freitag", "vendredi", "viernes", "venerdì", "vrijdag", "sexta", "金曜", "金曜日"],
            ["saturday", "samstag", "sonnabend", "samedi", "sábado", "sabato", "zaterdag", "土曜", "土曜日"],
            ["sunday", "sonntag", "dimanche", "domingo", "domenica", "zondag", "日曜", "日曜日"],
            ["january", "januar", "janvier", "enero", "gennaio", "januari", "janeiro", "一月"],
            ["february", "februar", "février", "febrero", "febbraio", "februari", "fevereiro", "二月"],
            ["march", "märz", "mars", "marzo", "maart", "março", "三月"],
            ["april", "avril", "abril", "aprile", "四月"],
            ["may", "mai", "mayo", "maggio", "mei", "maio", "五月"],
            ["june", "juni", "juin", "junio", "giugno", "junho", "六月"],
            ["july", "juli", "juillet", "julio", "luglio", "julho", "七月"],
            ["august", "août", "agosto", "augustus", "八月"],
            ["september", "septembre", "septiembre", "settembre", "setembro", "九月"],
            ["october", "oktober", "octobre", "octubre", "ottobre", "outubro", "十月"],
            ["november", "novembre", "noviembre", "novembro", "十一月"],
            ["december", "dezember", "décembre", "diciembre", "dicembre", "dezembro", "十二月"]
        ]
        var markers: [String: String] = [:]
        for group in groups {
            for spelling in group { markers[spelling] = group[0] }
        }
        return markers
    }()

    private static let japaneseCalendar = try! NSRegularExpression(
        pattern: "[月火水木金土日]曜(?:日)?|(?:十一|十二|十|[一二三四五六七八九])月"
    )

    private static func embeddedJapaneseMatches(
        in word: String,
        expression: NSRegularExpression
    ) -> [String] {
        // Both expressions require kana or kanji. Skip Foundation matching for
        // words containing only ASCII or the two-byte Latin accented letters.
        guard word.utf8.contains(where: { $0 >= 0xE3 }) else { return [] }
        let range = NSRange(word.startIndex..<word.endIndex, in: word)
        return expression.matches(in: word, range: range).compactMap { match in
            Range(match.range, in: word).map { String(word[$0]) }
        }
    }

    /// Words that carry meaning. Function words are excluded because they
    /// overlap heavily between any two English sentences, which would let an
    /// unrelated answer clear the threshold on "the", "and", and "to" alone.
    static func contentWords(in text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count > 2 && !functionWords.contains($0) }
        )
    }

    private static let functionWords: Set<String> = [
        "the", "and", "but", "for", "not", "you", "with", "that", "this",
        "have", "has", "had", "was", "were", "are", "its", "our", "their",
        "them", "they", "then", "than", "into", "onto", "from", "about",
        "can", "will", "would", "should", "could", "just", "get", "got",
        "her", "his", "she", "him", "who", "some", "any", "all"
    ]
}
